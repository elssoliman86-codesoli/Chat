import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../projects/projects.dart';

class AttachmentException implements Exception {
  AttachmentException(this.message);
  final String message;

  @override
  String toString() => message;
}

const Set<String> _imageExt = {'png', 'jpg', 'jpeg', 'webp', 'gif'};
const Set<String> _textExt = {
  'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'jsonl', 'xml', 'html', 'htm', 'yaml', 'yml', 'toml', 'ini',
  'log', 'rtf', 'tex', 'srt', 'vtt', 'sql', 'css', 'scss', 'js', 'mjs', 'ts', 'tsx', 'jsx', 'py', 'java', 'kt',
  'dart', 'c', 'h', 'cpp', 'hpp', 'cs', 'go', 'rs', 'rb', 'php', 'sh', 'bat', 'swift', 'm', 'r', 'lua', 'gradle',
  'properties', 'env', 'conf', 'cfg',
};

String extensionOf(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0 || i == name.length - 1) return '';
  return name.substring(i + 1).toLowerCase();
}

String mimeForImage(String ext) {
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return 'image/png';
  }
}

/// Maximum characters one document adds to a prompt.
const int maxDocumentChars = 200000;

String _clip(String text) {
  final t = text.trim();
  if (t.length <= maxDocumentChars) return t;
  return '${t.substring(0, maxDocumentChars)}\n[... cut: the file is longer than $maxDocumentChars characters]';
}

String _xmlText(String xml) {
  var s = xml.replaceAll(RegExp(r'</w:p>|</a:p>|</row>|<w:br/>|<w:tab/>'), '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
  return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

String _entry(Archive archive, String name) {
  final f = archive.findFile(name);
  if (f == null) return '';
  return utf8.decode(f.content as List<int>, allowMalformed: true);
}

/// Text of a .docx file.
String docxText(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  return _xmlText(_entry(archive, 'word/document.xml'));
}

/// Text of a .pptx file, slide by slide.
String pptxText(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final slides = archive.files
      .where((f) => f.isFile && RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
      .toList()
    ..sort((a, b) {
      int n(String s) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(s)?.group(1) ?? '0') ?? 0;
      return n(a.name).compareTo(n(b.name));
    });
  final out = StringBuffer();
  var i = 0;
  for (final f in slides) {
    i++;
    final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
    final texts = RegExp(r'<a:t>(.*?)</a:t>', dotAll: true).allMatches(xml).map((m) => m.group(1) ?? '').join(' ');
    out.writeln('--- Slide $i ---');
    out.writeln(_xmlText(texts));
  }
  return out.toString().trim();
}

/// Cell text of every sheet in an .xlsx file, as tab separated rows.
String xlsxText(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final shared = <String>[];
  final sharedXml = _entry(archive, 'xl/sharedStrings.xml');
  for (final m in RegExp(r'<si>(.*?)</si>', dotAll: true).allMatches(sharedXml)) {
    final parts = RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(m.group(1) ?? '').map((t) => t.group(1) ?? '');
    shared.add(_xmlText(parts.join()));
  }
  final sheets = archive.files
      .where((f) => f.isFile && RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(f.name))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final out = StringBuffer();
  var n = 0;
  for (final f in sheets) {
    n++;
    out.writeln('--- Sheet $n ---');
    final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
    for (final row in RegExp(r'<row[^>]*>(.*?)</row>', dotAll: true).allMatches(xml)) {
      final cells = <String>[];
      for (final c in RegExp(r'<c([^>]*?)(?:/>|>(.*?)</c>)', dotAll: true).allMatches(row.group(1) ?? '')) {
        final attrs = c.group(1) ?? '';
        final inner = c.group(2) ?? '';
        final value = RegExp(r'<v>(.*?)</v>', dotAll: true).firstMatch(inner)?.group(1) ?? '';
        if (attrs.contains('t="s"')) {
          final idx = int.tryParse(value) ?? -1;
          cells.add(idx >= 0 && idx < shared.length ? shared[idx] : '');
        } else if (attrs.contains('t="inlineStr"')) {
          cells.add(_xmlText(RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).firstMatch(inner)?.group(1) ?? ''));
        } else {
          cells.add(value);
        }
      }
      if (cells.any((c) => c.isNotEmpty)) out.writeln(cells.join('\t'));
    }
  }
  return out.toString().trim();
}

/// Copies files into app storage and reads documents into text.
class AttachmentService {
  Directory? _dir;

  Future<Directory> _folder() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/attachments');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  Future<Attachment> _projectAttachment(String projectId, String projectName, String name, int size, String summary) async {
    final files = await projects.list(projectId);
    final b = StringBuffer('[[project:$projectId]]\n"$name" was unpacked into the project "$projectName" on the phone. $summary '
        '${files.length} files in total. Work on it with the project_* tools (project_list, project_search, project_read, project_edit, project_write).\n\nFiles:\n');
    for (final f in files.take(150)) {
      b.writeln(f.path);
    }
    if (files.length > 150) b.writeln('… ${files.length - 150} more. Use project_list with a folder path to see them.');
    return Attachment(id: newId(), name: name, mime: 'application/zip', kind: AttachmentKind.text, size: size, text: b.toString());
  }

  /// Copies a whole folder from the phone into a new project.
  Future<Attachment> ingestFolder(String folder) async {
    final name = folder.split('/').where((s) => s.isNotEmpty).last;
    try {
      final (p, summary) = await projects.importFolder(folder, name);
      return _projectAttachment(p.id, p.name, name, 0, summary);
    } catch (e) {
      throw AttachmentException('Could not read that folder. Android may block it: put the files in a ZIP and attach the ZIP instead.');
    }
  }

  /// Turns a picked file into an attachment. Throws [AttachmentException] when it cannot be used.
  Future<Attachment> ingest(String sourcePath, String name) async {
    final file = File(sourcePath);
    if (!await file.exists()) throw AttachmentException('Could not read $name');
    final ext = extensionOf(name);
    final size = await file.length();
    final id = newId();

    if (_imageExt.contains(ext)) {
      if (size > 20 * 1024 * 1024) throw AttachmentException('$name is larger than 20 MB');
      final folder = await _folder();
      final stored = '${folder.path}/${id}_$name';
      await file.copy(stored);
      return Attachment(id: id, name: name, mime: mimeForImage(ext), kind: AttachmentKind.image, path: stored, size: size);
    }
    if (ext == 'pdf') {
      if (size > 32 * 1024 * 1024) throw AttachmentException('$name is larger than 32 MB');
      final folder = await _folder();
      final stored = '${folder.path}/${id}_$name';
      await file.copy(stored);
      return Attachment(id: id, name: name, mime: 'application/pdf', kind: AttachmentKind.pdf, path: stored, size: size);
    }
    if (ext == 'zip') {
      if (size > 400 * 1024 * 1024) throw AttachmentException('$name is larger than 400 MB');
      try {
        final (p, summary) = await projects.importZip(sourcePath, name);
        return _projectAttachment(p.id, p.name, name, size, summary);
      } catch (e) {
        throw AttachmentException('Could not open $name as a project');
      }
    }
    if (size > 60 * 1024 * 1024) throw AttachmentException('$name is larger than 60 MB');
    String text;
    final bytes = await file.readAsBytes();
    try {
      if (ext == 'docx') {
        text = docxText(bytes);
      } else if (ext == 'pptx') {
        text = pptxText(bytes);
      } else if (ext == 'xlsx') {
        text = xlsxText(bytes);
      } else if (_textExt.contains(ext) || ext.isEmpty) {
        text = utf8.decode(bytes, allowMalformed: true);
      } else {
        throw AttachmentException('".$ext" files are not supported yet');
      }
    } on AttachmentException {
      rethrow;
    } catch (_) {
      throw AttachmentException('Could not read $name');
    }
    if (text.trim().isEmpty) throw AttachmentException('$name has no readable text');
    return Attachment(
      id: id,
      name: name,
      mime: 'text/plain',
      kind: AttachmentKind.text,
      size: size,
      text: _clip(text),
    );
  }
}
