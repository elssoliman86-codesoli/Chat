import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show compute;

/// Everything the app can say about a file it cannot (or should not) read in full — an unknown
/// binary, a video, a multi-gigabyte log — so that any file, of any type and size, can still be
/// attached: the model gets an honest description of it instead of the app refusing the upload.

String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[i]}';
}

bool _startsWith(List<int> b, List<int> magic, [int at = 0]) {
  if (b.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[at + i] != magic[i]) return false;
  }
  return true;
}

List<int> _ascii(String s) => s.codeUnits;

/// A short label for what a file is, from its first bytes (magic numbers) and extension — '' when
/// nothing is recognized.
String sniffType(List<int> h, String ext) {
  if (_startsWith(h, [0x89, 0x50, 0x4E, 0x47])) return 'PNG image';
  if (_startsWith(h, [0xFF, 0xD8, 0xFF])) return 'JPEG image';
  if (_startsWith(h, _ascii('GIF8'))) return 'GIF image';
  if (_startsWith(h, _ascii('RIFF')) && _startsWith(h, _ascii('WEBP'), 8)) return 'WebP image';
  if (_startsWith(h, _ascii('RIFF')) && _startsWith(h, _ascii('WAVE'), 8)) return 'WAV audio';
  if (_startsWith(h, _ascii('RIFF')) && _startsWith(h, _ascii('AVI '), 8)) return 'AVI video';
  if (_startsWith(h, _ascii('BM'))) return 'BMP image';
  if (_startsWith(h, [0x49, 0x49, 0x2A, 0x00]) || _startsWith(h, [0x4D, 0x4D, 0x00, 0x2A])) return 'TIFF image';
  if (_startsWith(h, _ascii('8BPS'))) return 'Photoshop document';
  if (_startsWith(h, _ascii('%PDF'))) return 'PDF document';
  if (_startsWith(h, _ascii('ftyp'), 4)) {
    final brand = h.length >= 12 ? String.fromCharCodes(h.sublist(8, 12)) : '';
    if (brand.startsWith('heic') || brand.startsWith('heix') || brand.startsWith('mif1')) return 'HEIC image';
    if (brand == 'qt  ') return 'QuickTime video';
    if (brand.startsWith('M4A')) return 'M4A audio';
    return 'MP4 video';
  }
  if (_startsWith(h, [0x1A, 0x45, 0xDF, 0xA3])) return ext == 'webm' ? 'WebM video' : 'Matroska video';
  if (_startsWith(h, _ascii('ID3')) || (h.length > 1 && h[0] == 0xFF && (h[1] & 0xE0) == 0xE0)) return 'MP3 audio';
  if (_startsWith(h, _ascii('OggS'))) return 'Ogg audio/video';
  if (_startsWith(h, _ascii('fLaC'))) return 'FLAC audio';
  if (_startsWith(h, [0x50, 0x4B, 0x03, 0x04]) || _startsWith(h, [0x50, 0x4B, 0x05, 0x06])) {
    switch (ext) {
      case 'apk':
        return 'Android app (APK, a ZIP)';
      case 'aab':
        return 'Android app bundle (a ZIP)';
      case 'jar':
        return 'Java archive (JAR, a ZIP)';
      case 'epub':
        return 'EPUB book (a ZIP)';
      case 'docx':
      case 'xlsx':
      case 'pptx':
        return 'Office document (a ZIP)';
      case 'odt':
      case 'ods':
      case 'odp':
        return 'OpenDocument file (a ZIP)';
      default:
        return 'ZIP archive';
    }
  }
  if (_startsWith(h, [0x1F, 0x8B])) return 'gzip archive';
  if (_startsWith(h, _ascii('BZh'))) return 'bzip2 archive';
  if (_startsWith(h, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return '7-Zip archive';
  if (_startsWith(h, _ascii('Rar!'))) return 'RAR archive';
  if (_startsWith(h, [0xFD, 0x37, 0x7A, 0x58, 0x5A])) return 'xz archive';
  if (_startsWith(h, _ascii('ustar'), 257)) return 'tar archive';
  if (_startsWith(h, [0x4D, 0x5A])) return 'Windows executable (EXE/DLL)';
  if (_startsWith(h, [0x7F, 0x45, 0x4C, 0x46])) return 'ELF executable/library';
  if (_startsWith(h, [0xCA, 0xFE, 0xBA, 0xBE])) return 'Java class file or Mach-O universal binary';
  if (_startsWith(h, _ascii('dex\n'))) return 'Android DEX bytecode';
  if (_startsWith(h, [0x00, 0x61, 0x73, 0x6D])) return 'WebAssembly module';
  if (_startsWith(h, _ascii('SQLite format 3'))) return 'SQLite database';
  if (_startsWith(h, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])) return 'Legacy Microsoft Office / OLE file (DOC, XLS, PPT, MSI)';
  if (_startsWith(h, [0x00, 0x01, 0x00, 0x00]) || _startsWith(h, _ascii('OTTO'))) return 'TrueType/OpenType font';
  if (_startsWith(h, _ascii('wOFF')) || _startsWith(h, _ascii('wOF2'))) return 'WOFF web font';
  return '';
}

/// Whether the start of a file reads as text (any encoding that is not full of NUL/control bytes)
/// rather than binary — the decision that replaces trusting the file extension.
bool looksLikeText(List<int> head) {
  if (head.isEmpty) return true;
  // UTF-16 with a byte-order mark is text even though it is full of NULs.
  if (head.length >= 2 && ((head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF))) return true;
  var control = 0;
  for (final b in head) {
    if (b == 0) return false;
    if (b < 9 || (b > 13 && b < 32 && b != 27)) control++;
  }
  return control * 50 < head.length; // under 2% control bytes
}

/// Runs of printable text found inside binary data, like the Unix `strings` tool — often the only
/// readable parts of an executable, a media file's tags, or a database.
String printableStrings(List<int> bytes, {int minLen = 6, int maxChars = 4000, int maxLines = 150}) {
  final out = StringBuffer();
  final run = StringBuffer();
  var lines = 0;
  void flush() {
    if (run.length >= minLen && out.length < maxChars && lines < maxLines) {
      out.writeln(run.toString().length > 160 ? '${run.toString().substring(0, 160)}…' : run.toString());
      lines++;
    }
    run.clear();
  }

  for (final b in bytes) {
    if ((b >= 32 && b < 127) || b == 9) {
      run.writeCharCode(b);
    } else {
      flush();
      if (out.length >= maxChars || lines >= maxLines) break;
    }
  }
  flush();
  return out.toString().trimRight();
}

String hexHead(List<int> bytes, [int n = 32]) =>
    bytes.take(n).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

Future<List<int>> readHead(File f, int n) async {
  final out = <int>[];
  await for (final chunk in f.openRead(0, n)) {
    out.addAll(chunk);
    if (out.length >= n) break;
  }
  return out;
}

Future<List<int>> _readRange(File f, int start, int end) async {
  final out = <int>[];
  await for (final chunk in f.openRead(start, end)) {
    out.addAll(chunk);
  }
  return out;
}

/// The text of a text file of any size: whole when small; for a big one the first and last parts with
/// the middle cut out (and a line count from streaming the whole file once), so a multi-gigabyte log
/// never has to fit in memory.
Future<String> readTextCapped(File f, int size, {int fullLimit = 8 * 1024 * 1024, int headBytes = 300000, int tailBytes = 100000}) async {
  if (size <= fullLimit) {
    return utf8.decode(await f.readAsBytes(), allowMalformed: true);
  }
  var lines = 0;
  await for (final chunk in f.openRead()) {
    for (final b in chunk) {
      if (b == 10) lines++;
    }
  }
  final head = utf8.decode(await _readRange(f, 0, headBytes), allowMalformed: true);
  final tail = utf8.decode(await _readRange(f, math.max(headBytes, size - tailBytes), size), allowMalformed: true);
  final omitted = size - headBytes - tailBytes;
  return '[Large text file: ${humanSize(size)}, about ${lines + 1} lines. Showing the first ${humanSize(headBytes)} and the last '
      '${humanSize(tailBytes)}; ${humanSize(math.max(0, omitted))} in the middle is not shown.]\n$head\n\n[... middle of the file not shown ...]\n\n$tail';
}

String _zipListingTask(String path) {
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    final files = archive.files.where((f) => f.isFile).toList();
    final b = StringBuffer('Contains ${files.length} files:\n');
    for (final f in files.take(200)) {
      b.writeln('  ${f.name}  (${humanSize(f.size)})');
    }
    if (files.length > 200) b.writeln('  … and ${files.length - 200} more');
    return b.toString().trimRight();
  } catch (_) {
    return '';
  } finally {
    input.close();
  }
}

/// A listing of a ZIP-format file's entries (APK, JAR, EPUB, …), or '' when it cannot be read as one.
Future<String> zipListing(String path) => compute(_zipListingTask, path);

/// The report attached in place of a file's content: what it is, how big, and whatever could be read
/// from it without parsing it fully.
Future<String> binaryReport(File f, String name, int size, String ext) async {
  final head = await readHead(f, 4 * 1024 * 1024);
  final type = sniffType(head, ext);
  final b = StringBuffer();
  b.writeln('[Not a text file: "$name", ${humanSize(size)}${type.isEmpty ? '' : ', $type'}]');
  b.writeln('This app cannot show the model this file\'s contents directly, so this is what could be read from it without opening it '
      'fully. The file itself is still on the person\'s phone — ask them for specifics, or for a text export of it, if you need more.');
  b.writeln('- Extension: ${ext.isEmpty ? '(none)' : '.$ext'}');
  b.writeln('- First bytes (hex): ${hexHead(head)}');
  if (type.contains('ZIP') || type.contains('(a ZIP)') || type.contains('archive') && type.contains('ZIP')) {
    final listing = await zipListing(f.path);
    if (listing.isNotEmpty) b.writeln('- Archive entries:\n$listing');
  }
  final strings = printableStrings(head);
  if (strings.isNotEmpty && strings.split('\n').length >= 3) {
    b.writeln('- Readable text found inside (first part of the file):\n$strings');
  }
  return b.toString().trimRight();
}
