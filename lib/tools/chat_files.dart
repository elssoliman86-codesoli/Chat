/// Reads the files and edits a helper chat wrote in its answer, and applies them to text.
///
/// A chat website cannot make files: it writes names and code in its reply. The app asks it for a fixed format
/// ([kFilesFormat] / [kEditsFormat]) and this file turns the reply back into real files, so nobody has to copy and paste.
library;

/// Appended to a message when the answer should be whole files.
const String kFilesFormat = '''

ANSWER FORMAT (a program reads your answer, so follow it exactly):
For every file write one line "=== FILE: relative/path/name.ext ===" and right under it ONE code block holding the COMPLETE final content of that file. No "...", no placeholders, no "rest unchanged". No other text between the files; one short sentence before the first file is fine.
If the answer would be too long, finish whole files only and end with the line "=== MORE: names of the files still to come ===" and I will ask for them.''';

/// Appended to a message when the answer should be changes to existing files.
const String kEditsFormat = '''

ANSWER FORMAT (a program reads your answer, so follow it exactly):
For every existing file that changes write one line "=== EDIT: relative/path/name.ext ===" and then one or more blocks like this (inside a code block):
<<<<<<< SEARCH
(the exact existing lines, copied unchanged, enough of them to be unique in the file)
=======
(the new lines that replace them)
>>>>>>> REPLACE
Only the parts that change, never the whole file. For a brand new file use "=== FILE: relative/path/name.ext ===" followed by one code block with its complete content. No other text between files.
If the answer would be too long, finish whole files only and end with the line "=== MORE: names of the files still to come ===" and I will ask for them.''';

/// One search/replace of an edit.
class ChatEdit {
  const ChatEdit(this.search, this.replace);
  final String search;
  final String replace;
}

/// One file of a reply: either complete content, or a list of edits to an existing file.
class ChatFileItem {
  ChatFileItem(this.path, {this.content, List<ChatEdit>? edits, this.truncated = false}) : edits = edits ?? <ChatEdit>[];
  final String path;
  final String? content;
  final List<ChatEdit> edits;

  /// The reply stopped in the middle of this file (the code block or the edit was never closed).
  bool truncated;
  bool get isEdit => content == null;
}

class ChatFiles {
  ChatFiles(this.items, this.more);
  final List<ChatFileItem> items;

  /// Files the chat said are still to come.
  final List<String> more;
}

final RegExp _header = RegExp(r'^={2,}\s*(FILE|EDIT|MORE)\s*:\s*(.*?)\s*(?:={2,})?$', caseSensitive: false);
final RegExp _fenceOpen = RegExp(r'^\s{0,3}(`{3,}|~{3,})\s*[\w+#.\-]*\s*$');

String _plain(String line) => line.replaceAll(RegExp(r'^[\s*`#>_-]+|[\s*`_]+$'), '');

String _strip(String s, String chars) {
  var a = 0;
  var b = s.length;
  while (a < b && chars.contains(s[a])) {
    a++;
  }
  while (b > a && chars.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}

String _cleanPath(String p) {
  var s = _strip(p.trim(), '`\'"*').replaceAll('\\', '/');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  return s;
}

/// Finds the files in [text]. Understands "=== FILE: path ===" with a code block, "=== EDIT: path ===" with
/// SEARCH/REPLACE blocks, and (when there is no header at all) a code block preceded by a line naming a file.
ChatFiles parseChatFiles(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  final items = <ChatFileItem>[];
  final more = <String>[];

  (String, String)? head(String line) {
    final p = _plain(line);
    if (!p.startsWith('==')) return null;
    final m = _header.firstMatch(p);
    if (m == null) return null;
    return (m.group(1)!.toUpperCase(), m.group(2)!);
  }

  var i = 0;
  var sawHeader = false;
  while (i < lines.length) {
    final h = head(lines[i]);
    if (h == null) {
      i++;
      continue;
    }
    sawHeader = true;
    i++;
    if (h.$1 == 'MORE') {
      more.addAll(h.$2.split(RegExp(r'[,;]')).map(_cleanPath).where((e) => e.isNotEmpty));
      continue;
    }
    final path = _cleanPath(h.$2);
    // The section runs until the next header.
    var end = i;
    while (end < lines.length && head(lines[end]) == null) {
      end++;
    }
    final section = lines.sublist(i, end);
    i = end;
    if (path.isEmpty) continue;
    if (h.$1 == 'FILE') {
      items.add(_fileFromSection(path, section));
    } else {
      items.add(_editFromSection(path, section));
    }
  }

  if (!sawHeader) {
    // No headers: a code block with a line right before it that names a file.
    final nameLine = RegExp(r'^(?:file(?:name)?\s*[:：]\s*)?([\w@.\-/\\]+\.[A-Za-z0-9]{1,8})\s*[:：]?$', caseSensitive: false);
    var j = 0;
    String? pending;
    while (j < lines.length) {
      final open = _fenceOpen.firstMatch(lines[j]);
      if (open != null) {
        final fence = open.group(1)!;
        final body = <String>[];
        var k = j + 1;
        var closed = false;
        while (k < lines.length) {
          final t = lines[k].trim();
          if (t.isNotEmpty && t[0] == fence[0] && t.length >= fence.length && t.replaceAll(fence[0], '').isEmpty) {
            closed = true;
            break;
          }
          body.add(lines[k]);
          k++;
        }
        if (pending != null) {
          items.add(ChatFileItem(pending, content: _withNewline(body.join('\n')), truncated: !closed));
        }
        pending = null;
        j = k + 1;
        continue;
      }
      final t = _plain(lines[j]);
      final m = t.isEmpty ? null : nameLine.firstMatch(t);
      if (m != null) {
        pending = _cleanPath(m.group(1)!);
      } else if (t.isNotEmpty) {
        pending = null;
      }
      j++;
    }
  }
  return ChatFiles(items, more);
}

String _withNewline(String s) => s.endsWith('\n') ? s : '$s\n';

ChatFileItem _fileFromSection(String path, List<String> section) {
  var a = 0;
  while (a < section.length && section[a].trim().isEmpty) {
    a++;
  }
  if (a >= section.length) return ChatFileItem(path, content: '', truncated: true);
  final open = _fenceOpen.firstMatch(section[a]);
  if (open == null) {
    // No code block: everything up to the end of the section is the file.
    var b = section.length;
    while (b > a && section[b - 1].trim().isEmpty) {
      b--;
    }
    return ChatFileItem(path, content: _withNewline(section.sublist(a, b).join('\n')));
  }
  final fence = open.group(1)!;
  final body = <String>[];
  var closed = false;
  for (var k = a + 1; k < section.length; k++) {
    final t = section[k].trim();
    if (t.isNotEmpty && t[0] == fence[0] && t.length >= fence.length && t.replaceAll(fence[0], '').isEmpty) {
      closed = true;
      break;
    }
    body.add(section[k]);
  }
  return ChatFileItem(path, content: _withNewline(body.join('\n')), truncated: !closed);
}

ChatFileItem _editFromSection(String path, List<String> section) {
  final item = ChatFileItem(path, content: null);
  final start = RegExp(r'^\s*<{5,}\s*SEARCH\s*$', caseSensitive: false);
  final mid = RegExp(r'^\s*={5,}\s*$');
  final stop = RegExp(r'^\s*>{5,}\s*REPLACE\s*$', caseSensitive: false);
  var k = 0;
  while (k < section.length) {
    if (!start.hasMatch(section[k])) {
      k++;
      continue;
    }
    final search = <String>[];
    final replace = <String>[];
    var state = 0;
    k++;
    for (; k < section.length; k++) {
      final l = section[k];
      if (state == 0 && mid.hasMatch(l)) {
        state = 1;
      } else if (state == 1 && stop.hasMatch(l)) {
        state = 2;
        k++;
        break;
      } else if (state == 0) {
        search.add(l);
      } else {
        replace.add(l);
      }
    }
    if (state == 2) {
      item.edits.add(ChatEdit(search.join('\n'), replace.join('\n')));
    } else {
      item.truncated = true;
    }
  }
  if (item.edits.isEmpty) item.truncated = true;
  return item;
}

/// How one edit went.
class EditResult {
  const EditResult(this.ok, this.note);
  final bool ok;
  final String note;
}

class AppliedEdits {
  AppliedEdits(this.text, this.results);
  final String text;
  final List<EditResult> results;
  int get applied => results.where((r) => r.ok).length;
}

String _indentOf(String l) => l.substring(0, l.length - l.trimLeft().length);

/// Applies [edits] to [text] one after the other. A search must match exactly once; when it does not match
/// exactly, the same lines are looked for ignoring indentation and trailing spaces (chat sites mangle those).
AppliedEdits applyChatEdits(String text, List<ChatEdit> edits) {
  var cur = text;
  final results = <EditResult>[];
  for (var n = 0; n < edits.length; n++) {
    final e = edits[n];
    final label = 'edit ${n + 1}';
    if (e.search.trim().isEmpty) {
      if (cur.trim().isEmpty) {
        cur = e.replace;
        results.add(EditResult(true, '$label: file was empty, new content set'));
      } else {
        results.add(EditResult(false, '$label: the SEARCH part is empty, so it is unclear where the change goes'));
      }
      continue;
    }
    final exact = e.search.allMatches(cur).length;
    if (exact == 1) {
      cur = cur.replaceFirst(e.search, e.replace);
      results.add(EditResult(true, '$label: applied'));
      continue;
    }
    if (exact > 1) {
      results.add(EditResult(false, '$label: the SEARCH text appears $exact times, it needs more surrounding lines to be unique'));
      continue;
    }
    // Loose match by trimmed lines.
    final fileLines = cur.split('\n');
    final want = e.search.split('\n').map((l) => l.trim()).toList();
    while (want.isNotEmpty && want.first.isEmpty) {
      want.removeAt(0);
    }
    while (want.isNotEmpty && want.last.isEmpty) {
      want.removeLast();
    }
    final hits = <int>[];
    for (var s = 0; s + want.length <= fileLines.length; s++) {
      var all = true;
      for (var t = 0; t < want.length; t++) {
        if (fileLines[s + t].trim() != want[t]) {
          all = false;
          break;
        }
      }
      if (all) hits.add(s);
    }
    if (hits.length != 1) {
      results.add(EditResult(false, hits.isEmpty
          ? '$label: the SEARCH text was not found in the file (read the file again and send the real lines)'
          : '$label: the SEARCH text matches ${hits.length} places even ignoring indentation'));
      continue;
    }
    final s = hits.first;
    final searchLines = e.search.split('\n');
    final firstSearch = searchLines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final have = _indentOf(fileLines[s]);
    final said = _indentOf(firstSearch);
    var rep = e.replace.split('\n');
    if (have != said && have.startsWith(said)) {
      final extra = have.substring(said.length);
      rep = rep.map((l) => l.trim().isEmpty ? l : '$extra$l').toList();
    }
    fileLines.replaceRange(s, s + want.length, rep);
    cur = fileLines.join('\n');
    results.add(EditResult(true, '$label: applied (matched ignoring indentation)'));
  }
  return AppliedEdits(cur, results);
}

/// A short before/after view of a change, for the person's log and for sending back to a chat for review.
String briefChange(String before, String after, {int maxLines = 8}) {
  if (before == after) return 'no change';
  final a = before.split('\n');
  final b = after.split('\n');
  var s = 0;
  while (s < a.length && s < b.length && a[s] == b[s]) {
    s++;
  }
  var ea = a.length;
  var eb = b.length;
  while (ea > s && eb > s && a[ea - 1] == b[eb - 1]) {
    ea--;
    eb--;
  }
  String part(List<String> l, int from, int to, String mark) {
    final seg = l.sublist(from, to);
    final shown = seg.take(maxLines).map((x) => '$mark $x').join('\n');
    return seg.length > maxLines ? '$shown\n$mark … (${seg.length - maxLines} more lines)' : shown;
  }

  final removed = part(a, s, ea, '-');
  final added = part(b, s, eb, '+');
  return 'around line ${s + 1}: ${ea - s} line(s) -> ${eb - s} line(s)\n'
      '${removed.isEmpty ? '' : '$removed\n'}${added.isEmpty ? '' : added}'.trimRight();
}
