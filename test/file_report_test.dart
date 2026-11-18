import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/files/attachment_service.dart';
import 'package:omni_chat/files/file_report.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('omni_files'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File make(String name, List<int> bytes) => File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('humanSize', () {
    expect(humanSize(10), '10 B');
    expect(humanSize(2048), '2.0 KB');
    expect(humanSize(5 * 1024 * 1024), '5.0 MB');
    expect(humanSize(3 * 1024 * 1024 * 1024), '3.0 GB');
  });

  test('sniffType recognizes common formats by magic bytes', () {
    expect(sniffType([0x89, 0x50, 0x4E, 0x47, 0, 0], 'bin'), 'PNG image');
    expect(sniffType('%PDF-1.7'.codeUnits, ''), 'PDF document');
    expect(sniffType([0x50, 0x4B, 3, 4], 'apk'), contains('APK'));
    expect(sniffType([0x50, 0x4B, 3, 4], 'zip'), 'ZIP archive');
    expect(sniffType([0x7F, 0x45, 0x4C, 0x46], ''), contains('ELF'));
    expect(sniffType([0, 0, 0, 0x18, ...'ftypmp42'.codeUnits], 'mp4'), 'MP4 video');
    expect(sniffType('hello'.codeUnits, 'txt'), '');
  });

  test('looksLikeText separates text from binary', () {
    expect(looksLikeText('plain text\nwith lines'.codeUnits), isTrue);
    expect(looksLikeText(utf8.encode('مرحبا بالعالم')), isTrue);
    expect(looksLikeText([0x68, 0, 0x69, 0]), isFalse);
    expect(looksLikeText([0xFF, 0xFE, 0x68, 0, 0x69, 0]), isTrue);
    expect(looksLikeText(List<int>.generate(200, (i) => i % 7)), isFalse);
    expect(looksLikeText(const []), isTrue);
  });

  test('printableStrings finds readable runs', () {
    final bytes = [0, 1, 2, ...'hello world'.codeUnits, 0, 9, 9, ...'ab'.codeUnits, 0, ...'another string'.codeUnits];
    final s = printableStrings(bytes);
    expect(s, contains('hello world'));
    expect(s, contains('another string'));
    expect(s, isNot(contains('\nab\n')));
  });

  test('readTextCapped returns small files whole and cuts the middle of big ones', () async {
    final small = make('a.txt', 'one\ntwo'.codeUnits);
    expect(await readTextCapped(small, 7), 'one\ntwo');
    final big = make('b.log', List<int>.generate(2000, (i) => i % 50 == 49 ? 10 : 0x41 + i % 20));
    final out = await readTextCapped(big, 2000, fullLimit: 500, headBytes: 300, tailBytes: 100);
    expect(out, contains('Large text file'));
    expect(out, contains('middle of the file not shown'));
    expect(out.length, lessThan(1200));
  });

  test('binaryReport describes an unknown binary', () async {
    final f = make('tool.bin', [0x7F, 0x45, 0x4C, 0x46, 0, 0, 0, 1, ...'usr/lib/libc.so.6'.codeUnits, 0, ...'GLIBC_2.31 symbol'.codeUnits, 0, ...'/etc/passwd file'.codeUnits]);
    final r = await binaryReport(f, 'tool.bin', f.lengthSync(), 'bin');
    expect(r, contains('Not a text file'));
    expect(r, contains('ELF'));
    expect(r, contains('First bytes'));
    expect(r, contains('libc.so.6'));
  });

  group('AttachmentService.ingest accepts any file', () {
    final service = AttachmentService();

    test('unknown extension that is text is read as text', () async {
      final f = make('notes.weird', 'some text inside'.codeUnits);
      final a = await service.ingest(f.path, 'notes.weird');
      expect(a.kind, AttachmentKind.text);
      expect(a.text, contains('some text inside'));
    });

    test('binary with a made-up extension becomes a report instead of an error', () async {
      final f = make('data.xyz', List<int>.generate(500, (i) => i % 256));
      final a = await service.ingest(f.path, 'data.xyz');
      expect(a.kind, AttachmentKind.text);
      expect(a.text, contains('Not a text file'));
    });

    test('empty file is attached with a note', () async {
      final f = make('empty.txt', const []);
      final a = await service.ingest(f.path, 'empty.txt');
      expect(a.text, contains('Empty file'));
    });

    test('large text file is trimmed but accepted', () async {
      final line = '${'x' * 99}\n';
      final f = make('huge.log', const <int>[]);
      final sink = f.openWrite();
      for (var i = 0; i < 90000; i++) {
        sink.write(line);
      }
      await sink.close();
      final a = await service.ingest(f.path, 'huge.log');
      expect(a.kind, AttachmentKind.text);
      expect(a.text.length, lessThan(maxDocumentChars + 200));
    });

    test('odt text is extracted from content.xml', () async {
      final xml = '<office:text><text:p>Hello ODT</text:p><text:p>Second line</text:p></office:text>';
      final archive = Archive()..addFile(ArchiveFile('content.xml', xml.length, utf8.encode(xml)));
      final f = make('doc.odt', ZipEncoder().encode(archive)!);
      final a = await service.ingest(f.path, 'doc.odt');
      expect(a.kind, AttachmentKind.text);
      expect(a.text, contains('Hello ODT'));
      expect(a.text, contains('Second line'));
    });

    test('apk-like zip gets an entry listing in its report', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('AndroidManifest.xml', 4, [1, 2, 3, 4]))
        ..addFile(ArchiveFile('classes.dex', 4, [1, 2, 3, 4]));
      final f = make('app.apk', ZipEncoder().encode(archive)!);
      final a = await service.ingest(f.path, 'app.apk');
      expect(a.text, contains('AndroidManifest.xml'));
      expect(a.text, contains('classes.dex'));
    });
  });
}
