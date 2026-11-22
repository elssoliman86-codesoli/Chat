import 'dart:async';

/// Two workers wrote the same file in one run.
class FileConflict {
  FileConflict(this.path, this.first, this.second);
  final String path;
  final String first;
  final String second;

  @override
  String toString() => '$path ($first, then $second)';
}

/// Keeps workers from tripping over each other's files: a first-come queue per file (so two edits to the same
/// file never interleave), a record of who wrote what, and "claims" the scheduler uses to avoid starting two
/// tasks that mean to change the same file at the same time.
class FileLocks {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};
  final Map<String, String> _lastWriter = <String, String>{};
  final Map<String, Set<String>> _claims = <String, Set<String>>{};
  final List<FileConflict> conflicts = <FileConflict>[];

  static String normalize(String path) {
    var p = path.trim().replaceAll('\\', '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    p = p.replaceAll(RegExp(r'/+'), '/');
    if (p.startsWith('/')) p = p.substring(1);
    return p.toLowerCase();
  }

  /// Runs [fn] once every earlier holder of [path] is done. Others wait their turn; nothing is skipped.
  Future<T> synchronized<T>(String path, Future<T> Function() fn) async {
    final key = normalize(path);
    final previous = _tails[key] ?? Future<void>.value();
    final mine = Completer<void>();
    final tail = mine.future;
    _tails[key] = tail;
    try {
      try {
        await previous;
      } catch (_) {}
      return await fn();
    } finally {
      mine.complete();
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }

  /// Several files at once, always in the same order so two workers can never wait on each other.
  Future<T> synchronizedAll<T>(Iterable<String> paths, Future<T> Function() fn) {
    final keys = paths.map(normalize).toSet().toList()..sort();
    Future<T> go(int i) {
      if (i >= keys.length) return fn();
      return synchronized<T>(keys[i], () => go(i + 1));
    }

    return go(0);
  }

  /// Notes that [owner] wrote [path]. A different worker writing it later is a conflict (last writer wins,
  /// but the orchestrator reports it so nothing is silently overwritten).
  void recordWrite(String path, String owner) {
    final key = normalize(path);
    final last = _lastWriter[key];
    if (last != null && last != owner) conflicts.add(FileConflict(path, last, owner));
    _lastWriter[key] = owner;
  }

  // ── claims ──

  void claim(String owner, Iterable<String> paths) => _claims[owner] = paths.map(normalize).toSet();

  void release(String owner) => _claims.remove(owner);

  /// True when [paths] overlaps what another owner has claimed.
  bool blocked(String owner, Iterable<String> paths) {
    final mine = paths.map(normalize).toSet();
    if (mine.isEmpty) return false;
    for (final e in _claims.entries) {
      if (e.key == owner) continue;
      if (e.value.any(mine.contains)) return true;
    }
    return false;
  }
}
