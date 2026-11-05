import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart' show newId;

/// A folder of files the assistant builds or edits, kept on the phone.
class Project {
  Project({required this.id, required this.name, int? created, this.repo = '', this.ref = ''})
      : created = created ?? DateTime.now().millisecondsSinceEpoch;

  final String id;
  String name;
  final int created;

  /// owner/name when the project came from GitHub or was pushed there.
  String repo;
  String ref;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'name': name, 'created': created, 'repo': repo, 'ref': ref};

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String? ?? newId(),
        name: j['name'] as String? ?? 'Project',
        created: (j['created'] as num?)?.toInt(),
        repo: j['repo'] as String? ?? '',
        ref: j['ref'] as String? ?? '',
      );
}

class ProjectFile {
  const ProjectFile(this.path, this.size);
  final String path;
  final int size;
}

const Set<String> _skipDirs = {'.git', 'node_modules', '__MACOSX', '.gradle', '.dart_tool', 'build', '.idea', '.next', 'dist', '__pycache__'};
const Set<String> _skipNames = {'.DS_Store', 'Thumbs.db'};

/// Cleans a relative path from the model. Returns null when it is unsafe or empty.
String? safeRel(String raw) {
  final parts = <String>[];
  for (final p in raw.replaceAll('\\', '/').split('/')) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') return null;
    parts.add(p);
  }
  if (parts.isEmpty) return null;
  return parts.join('/');
}

// ---------------------------------------------------------------- work done off the UI thread

List<String> _listTask(String dir) {
  final root = Directory(dir);
  final out = <String>[];
  if (!root.existsSync()) return out;
  final base = root.path.length + 1;
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    if (e is File) {
      out.add('${e.path.substring(base)}\t${e.lengthSync()}');
    }
  }
  out.sort();
  return out;
}

Map<String, dynamic> _unzipTask(Map<String, dynamic> a) {
  final zipPath = a['zip'] as String;
  final dest = a['dest'] as String;
  final input = InputFileStream(zipPath);
  final archive = ZipDecoder().decodeBuffer(input);
  final names = <String>[];
  for (final f in archive.files) {
    if (f.isFile) names.add(f.name.replaceAll('\\', '/'));
  }
  // One folder around everything (like GitHub zips) is removed.
  String strip = '';
  if (names.isNotEmpty) {
    final first = names.first.split('/').first;
    if (names.every((n) => n.startsWith('$first/') && n.length > first.length + 1)) strip = '$first/';
  }
  var count = 0;
  var skipped = 0;
  var bytes = 0;
  for (final f in archive.files) {
    if (!f.isFile) continue;
    var name = f.name.replaceAll('\\', '/');
    if (strip.isNotEmpty) name = name.substring(strip.length);
    final rel = safeRel(name);
    if (rel == null) {
      skipped++;
      continue;
    }
    final segs = rel.split('/');
    if (segs.any(_skipDirs.contains) || _skipNames.contains(segs.last)) {
      skipped++;
      continue;
    }
    final out = File('$dest/$rel');
    out.parent.createSync(recursive: true);
    final data = f.content as List<int>;
    out.writeAsBytesSync(data);
    count++;
    bytes += data.length;
  }
  input.close();
  return <String, dynamic>{'count': count, 'skipped': skipped, 'bytes': bytes};
}

int _hash(List<int> data) {
  var h = 0x811c9dc5;
  for (final b in data) {
    h ^= b;
    h = (h * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return h;
}

Map<String, int> _baselineTask(String dir) {
  final root = Directory(dir);
  final out = <String, int>{};
  if (!root.existsSync()) return out;
  final base = root.path.length + 1;
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    if (e is File) out[e.path.substring(base)] = _hash(e.readAsBytesSync());
  }
  return out;
}

Map<String, dynamic> _changesTask(Map<String, dynamic> a) {
  final dir = a['dir'] as String;
  final old = (a['baseline'] as Map).map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
  final now = <String, int>{};
  final changed = <Map<String, String>>[];
  final skippedBinary = <String>[];
  final root = Directory(dir);
  final base = root.path.length + 1;
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(base);
    final data = e.readAsBytesSync();
    final h = _hash(data);
    now[rel] = h;
    if (old[rel] == h) continue;
    if (_looksBinary(data)) {
      skippedBinary.add(rel);
      continue;
    }
    changed.add(<String, String>{'path': rel, 'content': utf8.decode(data, allowMalformed: true)});
  }
  final deleted = old.keys.where((k) => !now.containsKey(k)).toList();
  return <String, dynamic>{'changed': changed, 'deleted': deleted, 'binary': skippedBinary, 'now': now};
}

bool _looksBinary(List<int> data) {
  final n = data.length < 4000 ? data.length : 4000;
  for (var i = 0; i < n; i++) {
    if (data[i] == 0) return true;
  }
  return false;
}

List<String> _searchTask(Map<String, dynamic> a) {
  final dir = a['dir'] as String;
  final query = a['query'] as String;
  final isRegex = a['regex'] as bool;
  final prefix = a['prefix'] as String;
  final limit = a['limit'] as int;
  RegExp? re;
  if (isRegex) {
    re = RegExp(query, caseSensitive: false);
  }
  final needle = query.toLowerCase();
  final root = Directory(dir);
  final out = <String>[];
  if (!root.existsSync()) return out;
  final base = root.path.length + 1;
  final files = root.listSync(recursive: true, followLinks: false).whereType<File>().toList()..sort((x, y) => x.path.compareTo(y.path));
  for (final f in files) {
    final rel = f.path.substring(base);
    if (prefix.isNotEmpty && !rel.startsWith(prefix)) continue;
    if (f.lengthSync() > 1500000) continue;
    final data = f.readAsBytesSync();
    if (_looksBinary(data)) continue;
    final lines = const LineSplitter().convert(utf8.decode(data, allowMalformed: true));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final hit = re != null ? re.hasMatch(line) : line.toLowerCase().contains(needle);
      if (hit) {
        out.add('$rel:${i + 1}: ${line.length > 200 ? line.substring(0, 200) : line}');
        if (out.length >= limit) return out;
      }
    }
  }
  return out;
}

int _copyTreeTask(Map<String, String> a) {
  final src = Directory(a['src']!);
  final dest = a['dest']!;
  var count = 0;
  final base = src.path.length + 1;
  for (final e in src.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(base).replaceAll('\\', '/');
    final segs = rel.split('/');
    if (segs.any(_skipDirs.contains) || _skipNames.contains(segs.last)) continue;
    final out = File('$dest/$rel');
    out.parent.createSync(recursive: true);
    e.copySync(out.path);
    count++;
  }
  return count;
}

String _zipTask(Map<String, String> a) {
  final enc = ZipFileEncoder();
  enc.zipDirectory(Directory(a['dir']!), filename: a['out']);
  return a['out']!;
}

// ---------------------------------------------------------------- the store

class ProjectStore extends ChangeNotifier {
  Directory? _root;
  final List<Project> projects = <Project>[];
  bool _loaded = false;

  Future<Directory> _base() async {
    final cached = _root;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/projects');
    if (!await d.exists()) await d.create(recursive: true);
    _root = d;
    return d;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final base = await _base();
    final meta = File('${base.path}/index.json');
    if (await meta.exists()) {
      try {
        final j = jsonDecode(await meta.readAsString());
        if (j is List) {
          projects
            ..clear()
            ..addAll(j.whereType<Map>().map((m) => Project.fromJson(m.cast<String, dynamic>())));
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final base = await _base();
    await File('${base.path}/index.json').writeAsString(jsonEncode(projects.map((p) => p.toJson()).toList()));
    notifyListeners();
  }

  Project? byId(String id) {
    for (final p in projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<String> dirOf(String id) async => '${(await _base()).path}/$id/files';

  Future<Project> create(String name, {String repo = '', String ref = ''}) async {
    await load();
    final clean = name.trim().isEmpty ? 'Project' : name.trim();
    final p = Project(id: newId(), name: clean, repo: repo, ref: ref);
    await Directory(await dirOf(p.id)).create(recursive: true);
    projects.insert(0, p);
    await _save();
    return p;
  }

  Future<void> rename(String id, String name) async {
    final p = byId(id);
    if (p == null || name.trim().isEmpty) return;
    p.name = name.trim();
    await _save();
  }

  Future<void> setRepo(String id, String repo, String ref) async {
    final p = byId(id);
    if (p == null) return;
    p.repo = repo;
    p.ref = ref;
    await _save();
  }

  Future<void> delete(String id) async {
    final base = await _base();
    final d = Directory('${base.path}/$id');
    if (await d.exists()) await d.delete(recursive: true);
    projects.removeWhere((p) => p.id == id);
    await _save();
  }

  // ------------------------------------------------------------ files

  Future<List<ProjectFile>> list(String id) async {
    final rows = await compute(_listTask, await dirOf(id));
    return rows.map((r) {
      final i = r.lastIndexOf('\t');
      return ProjectFile(r.substring(0, i), int.tryParse(r.substring(i + 1)) ?? 0);
    }).toList();
  }

  Future<int> write(String id, List<(String, String)> files) async {
    final dir = await dirOf(id);
    var n = 0;
    for (final (path, content) in files) {
      final rel = safeRel(path);
      if (rel == null) continue;
      final f = File('$dir/$rel');
      await f.parent.create(recursive: true);
      await f.writeAsString(content);
      n++;
    }
    notifyListeners();
    return n;
  }

  Future<void> writeBytes(String id, String path, List<int> bytes) async {
    final rel = safeRel(path);
    if (rel == null) throw Exception('Bad path');
    final f = File('${await dirOf(id)}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
    notifyListeners();
  }

  /// Text of a file, or null when missing. Binary files give a short note instead.
  Future<String?> readText(String id, String path) async {
    final rel = safeRel(path);
    if (rel == null) return null;
    final f = File('${await dirOf(id)}/$rel');
    if (!await f.exists()) return null;
    final data = await f.readAsBytes();
    if (_looksBinary(data)) return '[binary file, ${data.length} bytes]';
    return utf8.decode(data, allowMalformed: true);
  }

  Future<bool> remove(String id, String path) async {
    final rel = safeRel(path);
    if (rel == null) return false;
    final dir = await dirOf(id);
    final f = File('$dir/$rel');
    if (await f.exists()) {
      await f.delete();
      notifyListeners();
      return true;
    }
    final d = Directory('$dir/$rel');
    if (await d.exists()) {
      await d.delete(recursive: true);
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<bool> move(String id, String from, String to) async {
    final a = safeRel(from);
    final b = safeRel(to);
    if (a == null || b == null) return false;
    final dir = await dirOf(id);
    final type = await FileSystemEntity.type('$dir/$a');
    if (type == FileSystemEntityType.notFound) return false;
    await Directory('$dir/$b').parent.create(recursive: true);
    if (type == FileSystemEntityType.directory) {
      await Directory('$dir/$a').rename('$dir/$b');
    } else {
      await File('$dir/$a').rename('$dir/$b');
    }
    notifyListeners();
    return true;
  }

  Future<List<String>> search(String id, String query, {bool regex = false, String prefix = '', int limit = 80}) async {
    return compute(_searchTask, <String, dynamic>{
      'dir': await dirOf(id),
      'query': query,
      'regex': regex,
      'prefix': safeRel(prefix) ?? '',
      'limit': limit,
    });
  }

  // ------------------------------------------------------------ import and export

  Future<String> _tempFile(String name) async {
    final t = await getTemporaryDirectory();
    return '${t.path}/$name';
  }

  /// Unpacks a ZIP into a new project. Returns the project and a summary of what was imported.
  Future<(Project, String)> importZip(String zipPath, String name, {String repo = '', String ref = ''}) async {
    final base = name.replaceAll(RegExp(r'\.zip$', caseSensitive: false), '');
    final p = await create(base, repo: repo, ref: ref);
    final r = await compute(_unzipTask, <String, dynamic>{'zip': zipPath, 'dest': await dirOf(p.id)});
    await saveBaseline(p.id);
    notifyListeners();
    return (p, 'Imported ${r['count']} files (${((r['bytes'] as int) / 1024).round()} KB), skipped ${r['skipped']} (git, node_modules, build output).');
  }

  Future<(Project, String)> importFolder(String folder, String name) async {
    final p = await create(name);
    final n = await compute(_copyTreeTask, <String, String>{'src': folder, 'dest': await dirOf(p.id)});
    await saveBaseline(p.id);
    return (p, 'Copied $n files.');
  }

  /// Downloads a GitHub repository as a ZIP and unpacks it into a new project.
  Future<(Project, String)> importGithub(String repo, String ref, String token) async {
    final r = repo.trim().replaceAll(RegExp(r'^https?://(www\.)?github\.com/'), '').replaceAll(RegExp(r'\.git$'), '');
    final parts = r.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) throw Exception('Use owner/name or a github.com link.');
    final full = '${parts[0]}/${parts[1]}';
    var branch = ref.trim();
    if (branch.isEmpty && parts.length >= 4 && parts[2] == 'tree') branch = parts.sublist(3).join('/');
    final url = 'https://api.github.com/repos/$full/zipball${branch.isEmpty ? '' : '/$branch'}';
    final client = http.Client();
    final zip = await _tempFile('gh_${newId()}.zip');
    try {
      final headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'omni-chat',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };
      var req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(headers)
        ..followRedirects = false;
      var res = await client.send(req).timeout(const Duration(seconds: 40));
      var hops = 0;
      while ((res.statusCode == 301 || res.statusCode == 302 || res.statusCode == 307) && hops < 4) {
        final loc = res.headers['location'];
        if (loc == null) break;
        await res.stream.drain<void>();
        req = http.Request('GET', Uri.parse(loc))
          ..headers['User-Agent'] = 'omni-chat'
          ..followRedirects = false;
        res = await client.send(req).timeout(const Duration(seconds: 40));
        hops++;
      }
      if (res.statusCode == 404) throw Exception('Repository or branch not found (private repos need a token).');
      if (res.statusCode == 403 || res.statusCode == 429) throw Exception('GitHub refused (rate limit or no access). Add a token in Plugins.');
      if (res.statusCode != 200) throw Exception('GitHub HTTP ${res.statusCode}');
      final sink = File(zip).openWrite();
      var size = 0;
      await for (final chunk in res.stream) {
        size += chunk.length;
        if (size > 200 * 1024 * 1024) {
          await sink.close();
          throw Exception('The repository is larger than 200 MB.');
        }
        sink.add(chunk);
      }
      await sink.close();
    } finally {
      client.close();
    }
    try {
      final (p, summary) = await importZip(zip, parts[1], repo: full, ref: branch);
      return (p, summary);
    } finally {
      try {
        await File(zip).delete();
      } catch (_) {}
    }
  }

  /// Packs the project into a ZIP file and returns its path.
  Future<String> exportZip(String id) async {
    final p = byId(id);
    final base = await _base();
    final exports = Directory('${base.path}/exports');
    if (!await exports.exists()) await exports.create(recursive: true);
    final safeName = (p?.name ?? 'project').replaceAll(RegExp(r'[^\w\-. ]+'), '_').trim().replaceAll(' ', '_');
    final out = '${exports.path}/${safeName.isEmpty ? 'project' : safeName}.zip';
    final f = File(out);
    if (await f.exists()) await f.delete();
    return compute(_zipTask, <String, String>{'dir': await dirOf(id), 'out': out});
  }

  // ------------------------------------------------------------ git changes

  Future<Map<String, int>> _readBaseline(String id) async {
    final base = await _base();
    final f = File('${base.path}/$id/baseline.json');
    if (!await f.exists()) return <String, int>{};
    try {
      final j = jsonDecode(await f.readAsString()) as Map;
      return j.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> saveBaseline(String id) async {
    final now = await compute(_baselineTask, await dirOf(id));
    final base = await _base();
    await File('${base.path}/$id/baseline.json').writeAsString(jsonEncode(now));
  }

  /// Files added or changed since the project was imported or last pushed, and files that were deleted.
  Future<({List<Map<String, String>> changed, List<String> deleted, List<String> binary})> changes(String id) async {
    final r = await compute(_changesTask, <String, dynamic>{'dir': await dirOf(id), 'baseline': await _readBaseline(id)});
    return (
      changed: (r['changed'] as List).map((m) => (m as Map).cast<String, String>()).toList(),
      deleted: (r['deleted'] as List).cast<String>(),
      binary: (r['binary'] as List).cast<String>(),
    );
  }
}
