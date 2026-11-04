import 'dart:async';
import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';

const String browserUserAgent = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

/// Reads the text a page shows after its scripts ran, for the assistant's browse tool.
/// A one-pixel WebView in the app (see main.dart) keeps the engine alive.
class BrowserService {
  BrowserService._();
  static final BrowserService instance = BrowserService._();

  Completer<void>? _loaded;
  Future<void> _queue = Future<void>.value();
  bool attached = false;

  late final WebViewController controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setUserAgent(browserUserAgent)
    ..setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        final c = _loaded;
        if (c != null && !c.isCompleted) c.complete();
      },
      onWebResourceError: (e) {
        final c = _loaded;
        if ((e.isForMainFrame ?? true) && c != null && !c.isCompleted) {
          c.completeError(Exception(e.description));
        }
      },
    ));

  /// Text of [url] as a person would see it. Throws when it cannot load.
  Future<String> render(String url, {int maxChars = 9000}) {
    final run = _queue.then((_) => _render(url, maxChars));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<String> _render(String url, int maxChars) async {
    if (!attached) throw Exception('The built-in browser is not ready yet.');
    _loaded = Completer<void>();
    await controller.loadRequest(Uri.parse(url));
    await _loaded!.future.timeout(const Duration(seconds: 25));
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    return pageText(controller, maxChars);
  }
}

/// Title, address and visible text of whatever [c] shows now.
Future<String> pageText(WebViewController c, int maxChars) async {
  final raw = await c.runJavaScriptReturningResult(
      '(document.title||"") + "\\n" + location.href + "\\n\\n" + ((document.body && document.body.innerText) || "")');
  var text = raw.toString();
  if (text.startsWith('"')) {
    try {
      text = jsonDecode(text) as String;
    } catch (_) {}
  }
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return text.length > maxChars ? text.substring(0, maxChars) : text;
}
