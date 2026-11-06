import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Runs Python in-process on the phone (Pyodide, a full Python compiled to WebAssembly, loaded once
/// from a CDN into a hidden, never-shown web view). It is a sandbox: no shell, no access to the phone's
/// files or apps, nothing installed — good for the model to write and test a script before handing it over,
/// or to compute something, not for controlling the device or other programs.
class PythonRuntime {
  PythonRuntime._();
  static final PythonRuntime instance = PythonRuntime._();

  /// The hidden web view is only created once something needs it.
  final ValueNotifier<bool> needed = ValueNotifier<bool>(false);
  final GlobalKey viewKey = GlobalKey();

  late final WebViewController controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..addJavaScriptChannel('PyBridge', onMessageReceived: _onMessage)
    ..setNavigationDelegate(NavigationDelegate(onPageFinished: (_) {
      if (!_pageReady.isCompleted) _pageReady.complete();
    }));

  final Completer<void> _pageReady = Completer<void>();
  bool _started = false;
  bool _pyodideReady = false;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = <int, Completer<Map<String, dynamic>>>{};
  Future<void> _queue = Future<void>.value();

  void _onMessage(JavaScriptMessage m) {
    try {
      final j = jsonDecode(m.message) as Map<String, dynamic>;
      final id = (j['id'] as num).toInt();
      _pending.remove(id)?.complete(j);
    } catch (_) {}
  }

  Future<void> _ensureStarted() async {
    if (_started) {
      await _pageReady.future;
      return;
    }
    _started = true;
    needed.value = true;
    await controller.loadHtmlString(_bootHtml);
    await _pageReady.future.timeout(const Duration(seconds: 15));
  }

  /// Runs a snippet of Python. First call downloads the Python runtime (needs the internet, 15-40 seconds
  /// depending on the connection); later calls in the same session are quick, and earlier variables and
  /// imports stay available, like a notebook. Returns what was printed, the value of the last expression,
  /// and any error with its traceback.
  Future<String> run(String code, {Duration timeout = const Duration(seconds: 25)}) {
    final run = _queue.then((_) => _run(code, timeout));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<String> _run(String code, Duration timeout) async {
    try {
      await _ensureStarted();
    } catch (e) {
      return 'Could not start the Python runtime (needs the internet for the first run): $e';
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    await controller.runJavaScript('runPy($id, ${jsonEncode(code)});');
    // The very first call also has to download Pyodide itself (several MB) before any code runs, which
    // can take much longer than a normal run on a slow connection — give it real room, and say so in the
    // timeout message, instead of a short general timeout that reads as "your code is stuck".
    final effectiveTimeout = _pyodideReady ? timeout : (timeout < const Duration(seconds: 60) ? const Duration(seconds: 60) : timeout);
    Map<String, dynamic> j;
    try {
      j = await completer.future.timeout(effectiveTimeout);
    } on TimeoutException {
      _pending.remove(id);
      if (!_pyodideReady) {
        return 'Timed out after ${effectiveTimeout.inSeconds}s still starting Python for the first time (it downloads a '
            'few MB). This is most likely a slow or blocked internet connection, not the code. Try again, or check the '
            "connection.";
      }
      return 'Timed out after ${effectiveTimeout.inSeconds}s. The script may be stuck (an infinite loop, or waiting on input). Shorten it or break it into steps.';
    }
    _pyodideReady = true;
    final out = (j['out'] as String? ?? '').trim();
    final err = (j['err'] as String? ?? '').trim();
    if (j['ok'] != true) {
      final b = StringBuffer('Python error:\n${j['error']}');
      if (out.isNotEmpty) b.write('\n\nPrinted before the error:\n$out');
      if (err.isNotEmpty) b.write('\n\nstderr:\n$err');
      return b.toString();
    }
    final result = (j['result'] as String? ?? '');
    final b = StringBuffer();
    if (out.isNotEmpty) b.writeln(out);
    if (err.isNotEmpty) b.writeln('stderr:\n$err');
    if (result.isNotEmpty && result != 'None') b.writeln('= $result');
    return b.toString().trim().isEmpty ? '(ran with no output)' : b.toString().trim();
  }

  /// Clears variables and imports, starting the next run fresh.
  Future<void> reset() async {
    if (!_started) return;
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    await controller.runJavaScript('resetPy($id);');
    try {
      await completer.future.timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
}

const String _bootHtml = r'''
<!doctype html><html><head><meta charset="utf-8"></head><body>
<script src="https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js"></script>
<script>
let pyReady = null;
let pyodide = null;
let buf = {out: "", err: ""};
function boot() {
  pyReady = loadPyodide().then(function (py) {
    pyodide = py;
    py.setStdout({ batched: (s) => { buf.out += s + "\n"; } });
    py.setStderr({ batched: (s) => { buf.err += s + "\n"; } });
    return py;
  });
}
boot();
async function runPy(id, code) {
  buf = { out: "", err: "" };
  try {
    const py = await pyReady;
    let result;
    try {
      result = await py.runPythonAsync(code);
    } catch (e) {
      PyBridge.postMessage(JSON.stringify({ id: id, ok: false, out: buf.out, err: buf.err, error: String(e) }));
      return;
    }
    let rs = (result === undefined || result === null) ? "None" : String(result);
    PyBridge.postMessage(JSON.stringify({ id: id, ok: true, out: buf.out, err: buf.err, result: rs }));
  } catch (e) {
    PyBridge.postMessage(JSON.stringify({ id: id, ok: false, out: "", err: "", error: "Could not start Python: " + String(e) }));
  }
}
async function resetPy(id) {
  boot();
  await pyReady;
  PyBridge.postMessage(JSON.stringify({ id: id, ok: true, out: "", err: "", result: "" }));
}
</script>
</body></html>
''';

/// Mounts the hidden Python web view, far off screen, only once something has asked to run Python.
/// Put this inside the same Stack as the chat, alongside DockLayer.
class PythonRuntimeMount extends StatelessWidget {
  const PythonRuntimeMount({super.key});

  @override
  Widget build(BuildContext context) {
    final p = PythonRuntime.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: p.needed,
      builder: (context, needed, _) {
        if (!needed) return const SizedBox.shrink();
        // Kept small and near-transparent rather than off-canvas: a platform view (the WebView) is not
        // reliably clipped by a Positioned offset on every Android build, so this is what actually keeps
        // it from covering the chat. Its visible size does not matter, only that it keeps running.
        return Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: ExcludeSemantics(
            child: IgnorePointer(child: Opacity(opacity: 0.01, child: WebViewWidget(key: p.viewKey, controller: p.controller))),
          ),
        );
      },
    );
  }
}
