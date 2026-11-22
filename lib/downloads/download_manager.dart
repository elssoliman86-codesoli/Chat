import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import 'download_engine.dart';
import 'download_task.dart';

/// Saves through Android's own save picker (the person chooses the folder and name) and joins the parts
/// natively, so even a huge file never has to pass through the app's memory.
class PlatformSaver implements DownloadSaver {
  static const MethodChannel _channel = MethodChannel('omni/files');

  @override
  Future<String?> pickTarget(String name, String mime) async {
    try {
      return await _channel.invokeMethod<String>('pickSave', <String, dynamic>{
        'name': name,
        'mime': mime.isEmpty ? 'application/octet-stream' : mime,
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> merge(String target, List<String> parts) async {
    if (target.startsWith('content://')) {
      await _channel.invokeMethod<bool>('mergeInto', <String, dynamic>{'uri': target, 'parts': parts, 'deleteParts': true});
    } else {
      await mergeFiles(target, parts);
    }
  }

  /// Hands the link to Android's own download manager (Downloads folder, with a notification). Returns an error
  /// text, or null when it was accepted.
  static Future<String?> systemDownload(String url, {String name = '', String mime = '', Map<String, String> headers = const <String, String>{}}) async {
    try {
      await _channel.invokeMethod<bool>('systemDownload', <String, dynamic>{
        'url': url,
        'name': name,
        'mime': mime,
        'cookie': headers['Cookie'] ?? '',
        'ua': headers['User-Agent'] ?? '',
        'referer': headers['Referer'] ?? '',
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return e.toString();
    }
  }

  @override
  Future<void> open(String target, String mime) async {
    if (!target.startsWith('content://')) return;
    try {
      await _channel.invokeMethod<bool>('open', <String, dynamic>{'uri': target, 'mime': mime.isEmpty ? '*/*' : mime});
    } catch (_) {}
  }
}

/// All downloads of the built-in browser (and links added by hand): the list, the saved state, and the
/// scheduling of how many run at once.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  /// For tests: a manager with its own folder and saver.
  @visibleForTesting
  DownloadManager.forTest({required DownloadSaver saver, required Directory root, this.maxActive = 3}) {
    _saverOverride = saver;
    _root = root;
  }

  DownloadSaver? _saverOverride;
  DownloadSaver get saver => _saverOverride ??= PlatformSaver();
  late final DownloadEngine engine = DownloadEngine(saver: saver)..onState = _onState;

  final List<DownloadTask> tasks = <DownloadTask>[];
  int maxActive = 3;
  Directory? _root;
  bool _loaded = false;
  Timer? _saveTimer;

  Future<Directory> _dir() async {
    var d = _root;
    if (d == null) {
      final base = await getApplicationSupportDirectory();
      d = Directory('${base.path}${Platform.pathSeparator}downloads');
      _root = d;
    }
    await d.create(recursive: true);
    return d;
  }

  File _index(Directory d) => File('${d.path}${Platform.pathSeparator}index.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final d = await _dir();
      final f = _index(d);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is List) {
          for (final m in j.whereType<Map>()) {
            try {
              tasks.add(DownloadTask.fromJson(m.cast<String, dynamic>()));
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  void _onState(DownloadTask t) {
    _scheduleSave();
    notifyListeners();
    _pump();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    try {
      final d = await _dir();
      final tmp = File('${_index(d).path}.tmp');
      await tmp.writeAsString(jsonEncode(tasks.map((t) => t.toJson()).toList()));
      await tmp.rename(_index(d).path);
    } catch (_) {}
  }

  int get activeCount => tasks.where((t) => t.active).length;
  double get totalSpeed => tasks.where((t) => t.state == DownloadState.downloading).fold<double>(0, (a, t) => a + t.speed);

  Future<DownloadProbe> probe(String url, {Map<String, String> headers = const <String, String>{}, String nameHint = ''}) {
    return engine.probe(url, headers: headers, nameHint: nameHint);
  }

  /// Headers that make the download look like it came from the page the link was on.
  static Map<String, String> headersFor({String cookie = '', String userAgent = '', String referer = ''}) => <String, String>{
        if (cookie.isNotEmpty) 'Cookie': cookie,
        if (userAgent.isNotEmpty) 'User-Agent': userAgent,
        if (referer.isNotEmpty) 'Referer': referer,
      };

  /// Adds a download (probed and with its save location chosen) and starts it.
  Future<DownloadTask> add(
    DownloadProbe p, {
    required String target,
    String? fileName,
    Map<String, String> headers = const <String, String>{},
    int connections = 8,
  }) async {
    await load();
    final id = newId();
    final root = await _dir();
    final t = DownloadTask(
      id: id,
      url: p.url,
      fileName: fileName ?? p.fileName,
      headers: headers,
      mime: p.mime,
      total: p.total,
      resumable: p.resumable,
      etag: p.etag,
      lastModified: p.lastModified,
      target: target,
      connections: connections.clamp(1, 32),
    )..partsDir = '${root.path}${Platform.pathSeparator}$id';
    tasks.insert(0, t);
    t.state = DownloadState.queued;
    _onState(t);
    return t;
  }

  void _pump() {
    var running = activeCount;
    for (final t in tasks.reversed) {
      if (running >= maxActive) break;
      if (t.state == DownloadState.queued && !engine.isRunning(t.id)) {
        running++;
        t.state = DownloadState.probing;
        unawaited(engine.run(t).catchError((Object e) {
          t.state = DownloadState.failed;
          t.error = e.toString();
          _onState(t);
        }));
      }
    }
  }

  void pause(DownloadTask t) {
    if (t.state == DownloadState.queued) {
      t.state = DownloadState.paused;
      t.changed();
      _onState(t);
      return;
    }
    engine.pause(t);
  }

  void resume(DownloadTask t) {
    if (!t.canResume) return;
    t.state = DownloadState.queued;
    t.error = '';
    t.changed();
    _onState(t);
  }

  /// Stops it, deletes the part files and takes it off the list.
  Future<void> remove(DownloadTask t) async {
    if (t.state != DownloadState.completed) {
      await engine.discard(t);
    }
    tasks.remove(t);
    _scheduleSave();
    notifyListeners();
  }

  Future<void> open(DownloadTask t) => saver.open(t.target, t.mime);

  Future<void> clearFinished() async {
    tasks.removeWhere((t) => t.state == DownloadState.completed || t.state == DownloadState.cancelled);
    _scheduleSave();
    notifyListeners();
  }

  /// Waits until [t] is no longer running (tests).
  @visibleForTesting
  Future<void> settle(DownloadTask t, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (!engine.isRunning(t.id) && t.state != DownloadState.queued && t.state != DownloadState.probing) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
