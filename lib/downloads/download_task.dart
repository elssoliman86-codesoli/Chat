import 'package:flutter/foundation.dart';

enum DownloadState { queued, probing, downloading, paused, merging, completed, failed, cancelled }

/// One slice of a file. The file is cut into many of these and several are fetched at the same time; each
/// slice is kept in its own part file, so a stopped download carries on from exactly where each slice ended.
class Chunk {
  Chunk(this.index, this.start, this.end);

  final int index;

  /// First and last byte (inclusive) of the slice. A download of unknown size has one chunk with end -1.
  final int start;
  final int end;

  /// Bytes of this slice already on disk.
  int done = 0;

  /// Set when a slice of unknown length has been read to its end.
  bool finished = false;

  bool get bounded => end >= start;
  int get length => bounded ? end - start + 1 : -1;
  bool get complete => bounded ? done >= length : finished;

  Map<String, dynamic> toJson() => <String, dynamic>{'i': index, 's': start, 'e': end, 'd': done, 'f': finished};

  static Chunk fromJson(Map<String, dynamic> j) => Chunk(
        (j['i'] as num).toInt(),
        (j['s'] as num).toInt(),
        (j['e'] as num).toInt(),
      )
        ..done = (j['d'] as num?)?.toInt() ?? 0
        ..finished = j['f'] as bool? ?? false;
}

/// What a quick request to the link found out before the download starts.
class DownloadProbe {
  const DownloadProbe({
    required this.url,
    required this.fileName,
    required this.total,
    required this.resumable,
    this.mime = '',
    this.etag = '',
    this.lastModified = '',
  });

  final String url;
  final String fileName;

  /// Size in bytes, or -1 when the server does not say.
  final int total;

  /// True when the server accepts byte ranges: the file can be fetched in parts and resumed.
  final bool resumable;
  final String mime;
  final String etag;
  final String lastModified;
}

class DownloadTask extends ChangeNotifier {
  DownloadTask({
    required this.id,
    required this.url,
    required this.fileName,
    this.headers = const <String, String>{},
    this.mime = '',
    this.total = -1,
    this.resumable = false,
    this.etag = '',
    this.lastModified = '',
    this.target = '',
    this.connections = 8,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String url;
  String fileName;

  /// Cookie, User-Agent and Referer of the page the link came from, so protected links still work.
  Map<String, String> headers;
  String mime;
  int total;
  bool resumable;
  String etag;
  String lastModified;

  /// Where the finished file goes: a content:// address from the Android save picker, or a file path.
  String target;
  int connections;
  final DateTime createdAt;
  DateTime? finishedAt;

  DownloadState state = DownloadState.queued;
  String error = '';
  List<Chunk> chunks = <Chunk>[];

  /// Bytes per second right now.
  double speed = 0;

  /// Part files live here until the file is joined.
  String partsDir = '';

  int get received {
    var n = 0;
    for (final c in chunks) {
      n += c.bounded ? (c.done > c.length ? c.length : c.done) : c.done;
    }
    return n;
  }

  /// 0..1, or null when the size is unknown.
  double? get progress {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  Duration? get eta {
    if (total <= 0 || speed < 1) return null;
    final left = total - received;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).ceil());
  }

  bool get active => state == DownloadState.probing || state == DownloadState.downloading || state == DownloadState.merging;
  bool get canResume => state == DownloadState.paused || state == DownloadState.failed;

  void changed() => notifyListeners();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'url': url,
        'name': fileName,
        'headers': headers,
        'mime': mime,
        'total': total,
        'resumable': resumable,
        'etag': etag,
        'lm': lastModified,
        'target': target,
        'connections': connections,
        'created': createdAt.millisecondsSinceEpoch,
        'finished': finishedAt?.millisecondsSinceEpoch,
        'state': state.name,
        'error': error,
        'dir': partsDir,
        'chunks': chunks.map((c) => c.toJson()).toList(),
      };

  static DownloadTask fromJson(Map<String, dynamic> j) {
    final t = DownloadTask(
      id: j['id'] as String,
      url: j['url'] as String,
      fileName: j['name'] as String? ?? 'download',
      headers: ((j['headers'] as Map?) ?? const <String, dynamic>{}).map((k, v) => MapEntry(k.toString(), v.toString())),
      mime: j['mime'] as String? ?? '',
      total: (j['total'] as num?)?.toInt() ?? -1,
      resumable: j['resumable'] as bool? ?? false,
      etag: j['etag'] as String? ?? '',
      lastModified: j['lm'] as String? ?? '',
      target: j['target'] as String? ?? '',
      connections: (j['connections'] as num?)?.toInt() ?? 8,
      createdAt: DateTime.fromMillisecondsSinceEpoch((j['created'] as num?)?.toInt() ?? 0),
    );
    final fin = (j['finished'] as num?)?.toInt();
    if (fin != null) t.finishedAt = DateTime.fromMillisecondsSinceEpoch(fin);
    t.state = DownloadState.values.firstWhere((s) => s.name == j['state'], orElse: () => DownloadState.paused);
    t.error = j['error'] as String? ?? '';
    t.partsDir = j['dir'] as String? ?? '';
    final list = j['chunks'];
    if (list is List) {
      t.chunks = list.whereType<Map>().map((m) => Chunk.fromJson(m.cast<String, dynamic>())).toList();
    }
    // A download that was running when the app closed simply waits to be resumed.
    if (t.state == DownloadState.probing || t.state == DownloadState.downloading || t.state == DownloadState.merging || t.state == DownloadState.queued) {
      t.state = DownloadState.paused;
    }
    return t;
  }
}

/// The slices a file of [total] bytes is cut into. Small slices (1–16 MB) keep every connection busy
/// until the very end and make a retry cheap.
List<Chunk> planChunks(int total, int connections) {
  if (total <= 0) return <Chunk>[Chunk(0, 0, -1)];
  final want = (total / (connections.clamp(1, 64) * 8)).ceil();
  final size = want.clamp(1 << 20, 16 << 20);
  final out = <Chunk>[];
  var start = 0;
  var i = 0;
  while (start < total) {
    final end = (start + size - 1) < total - 1 ? start + size - 1 : total - 1;
    out.add(Chunk(i++, start, end));
    start = end + 1;
  }
  return out;
}

/// File name from a Content-Disposition header, or from the end of the address.
String fileNameFrom({String disposition = '', String url = '', String mime = ''}) {
  String clean(String s) {
    var n = s.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    n = n.replaceAll(RegExp(r'^\.+'), '');
    return n.length > 120 ? n.substring(n.length - 120) : n;
  }

  final star = RegExp(r"filename\*\s*=\s*([\w-]+)?'[^']*'([^;]+)", caseSensitive: false).firstMatch(disposition);
  if (star != null) {
    try {
      final n = clean(Uri.decodeComponent(star.group(2)!.trim()));
      if (n.isNotEmpty) return n;
    } catch (_) {}
  }
  final plain = RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false).firstMatch(disposition);
  if (plain != null) {
    final n = clean(plain.group(1)!);
    if (n.isNotEmpty) return n;
  }
  final u = Uri.tryParse(url);
  if (u != null && u.pathSegments.isNotEmpty) {
    var last = u.pathSegments.last;
    try {
      last = Uri.decodeComponent(last);
    } catch (_) {}
    final n = clean(last);
    if (n.isNotEmpty) return n;
  }
  return 'download${_extensionFor(mime)}';
}

String _extensionFor(String mime) {
  final m = mime.split(';').first.trim().toLowerCase();
  const map = <String, String>{
    'application/zip': '.zip',
    'application/pdf': '.pdf',
    'application/vnd.android.package-archive': '.apk',
    'video/mp4': '.mp4',
    'audio/mpeg': '.mp3',
    'image/png': '.png',
    'image/jpeg': '.jpg',
    'text/plain': '.txt',
  };
  return map[m] ?? '';
}

String formatBytes(num b) {
  if (b < 1024) return '${b.toInt()} B';
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : (v >= 10 ? 1 : 2))} ${units[u]}';
}

String formatSpeed(double bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';
