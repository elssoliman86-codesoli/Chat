import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../projects/projects.dart';
import 'file_report.dart';

class AttachmentException implements Exception {
  AttachmentException(this.message);
  final String message;

  @override
  String toString() => message;
}

const Set<String> _imageExt = {'png', 'jpg', 'jpeg', 'webp', 'gif'};

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

/// Largest image / PDF sent to the model as-is; bigger ones are described instead of refused.
const int maxInlineImageBytes = 20 * 1024 * 1024;
const int maxInlinePdfBytes = 32 * 1024 * 1024;
const int maxOfficeBytes = 60 * 1024 * 1024;

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

/// Text of an OpenDocument file (content.xml) or an EPUB (its XHTML chapters).
String zipDocumentText(List<int> bytes, String ext) {
  final archive = ZipDecoder().decodeBytes(bytes);
  if (ext == 'epub') {
    final pages = archive.files
        .where((f) => f.isFile && RegExp(r'\.(x?html?)$', caseSensitive: false).hasMatch(f.name))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final out = StringBuffer();
    for (final f in pages) {
      final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
      final body = xml.replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true), '').replaceAll(RegExp(r'</(p|div|h\d|li|br)\s*/?>'), '\n');
      out.writeln(_xmlText(body));
      out.writeln();
    }
    return out.toString().trim();
  }
  final xml = _entry(archive, 'content.xml')
      .replaceAll(RegExp(r'</text:p>|</text:h>|</table:table-row>|<text:line-break/>'), '\n')
      .replaceAll(RegExp(r'</table:table-cell>'), '\t');
  return _xmlText(xml);
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
      return await _projectAttachment(p.id, p.name, name, 0, summary);
    } catch (e) {
      throw AttachmentException('Could not read that folder. Android may block it: put the files in a ZIP and attach the ZIP instead.');
    }
  }

  Future<Attachment> _stored(File file, String name, String mime, AttachmentKind kind, int size, String id) async {
    final folder = await _folder();
    final stored = '${folder.path}/${id}_$name';
    await file.copy(stored);
    return Attachment(id: id, name: name, mime: mime, kind: kind, path: stored, size: size);
  }

  Attachment _textAttachment(String id, String name, int size, String text) =>
      Attachment(id: id, name: name, mime: 'text/plain', kind: AttachmentKind.text, size: size, text: _clip(text));

  /// Turns a picked file into an attachment. Any file of any type and size is accepted: what the
  /// model cannot read directly is described to it instead of being refused.
  Future<Attachment> ingest(String sourcePath, String name) async {
    final file = File(sourcePath);
    if (!await file.exists()) throw AttachmentException('Could not read $name');
    final ext = extensionOf(name);
    final size = await file.length();
    final id = newId();
    final head = await readHead(file, 4096);
    final sniffed = sniffType(head, ext);

    // Images are sent as they are; the provider clients downscale nothing, so huge ones are described.
    if (_imageExt.contains(ext) || sniffed == 'PNG image' || sniffed == 'JPEG image' || sniffed == 'GIF image' || sniffed == 'WebP image') {
      final realExt = sniffed == 'PNG image'
          ? 'png'
          : sniffed == 'JPEG image'
              ? 'jpg'
              : sniffed == 'GIF image'
                  ? 'gif'
                  : sniffed == 'WebP image'
                      ? 'webp'
                      : ext;
      if (size <= maxInlineImageBytes) {
        return _stored(file, name, mimeForImage(realExt), AttachmentKind.image, size, id);
      }
      return _textAttachment(id, name, size, await binaryReport(file, name, size, ext));
    }
    if (ext == 'pdf' || sniffed == 'PDF document') {
      if (size <= maxInlinePdfBytes) {
        return _stored(file, name, 'application/pdf', AttachmentKind.pdf, size, id);
      }
      return _textAttachment(id, name, size, await binaryReport(file, name, size, ext));
    }
    if (ext == 'zip' && sniffed == 'ZIP archive') {
      try {
        final (p, summary) = await projects.importZip(sourcePath, name);
        return await _projectAttachment(p.id, p.name, name, size, summary);
      } catch (_) {
        return _textAttachment(id, name, size, await binaryReport(file, name, size, ext));
      }
    }
    if (const {'docx', 'pptx', 'xlsx'}.contains(ext) && size <= maxOfficeBytes) {
      try {
        final bytes = await file.readAsBytes();
        final text = ext == 'docx' ? docxText(bytes) : ext == 'pptx' ? pptxText(bytes) : xlsxText(bytes);
        if (text.trim().isNotEmpty) return _textAttachment(id, name, size, text);
      } catch (_) {
        // fall through to the generic report
      }
    }
    if (const {'odt', 'ods', 'odp', 'epub'}.contains(ext) && size <= maxOfficeBytes) {
      try {
        final text = zipDocumentText(await file.readAsBytes(), ext);
        if (text.trim().isNotEmpty) return _textAttachment(id, name, size, text);
      } catch (_) {
        // fall through to the generic report
      }
    }
    if (looksLikeText(head)) {
      final text = await readTextCapped(file, size);
      if (text.trim().isEmpty) return _textAttachment(id, name, size, '[Empty file: "$name"]');
      return _textAttachment(id, name, size, text);
    }
    return _textAttachment(id, name, size, await binaryReport(file, name, size, ext));
  }
}
