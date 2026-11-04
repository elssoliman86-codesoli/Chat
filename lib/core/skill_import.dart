import 'models.dart';

/// Reads a SKILL.md file: optional YAML-style front matter with `name` and `description`, then the instructions.
Skill? parseSkillMarkdown(String source, {String fallbackName = 'Imported skill'}) {
  var text = source.replaceAll('\r\n', '\n').trim();
  if (text.isEmpty) return null;
  var name = '';
  var description = '';
  if (text.startsWith('---')) {
    final end = text.indexOf('\n---', 3);
    if (end > 0) {
      final head = text.substring(3, end);
      text = text.substring(end + 4).trim();
      final lines = head.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final m = RegExp(r'^(\w[\w-]*):\s*(.*)$').firstMatch(line);
        if (m == null) continue;
        final key = m.group(1)!;
        var value = (m.group(2) ?? '').trim();
        if (value == '>' || value == '>-' || value == '|' || value == '|-') {
          final buf = <String>[];
          while (i + 1 < lines.length && (lines[i + 1].startsWith(' ') || lines[i + 1].trim().isEmpty)) {
            i++;
            buf.add(lines[i].trim());
          }
          value = buf.where((e) => e.isNotEmpty).join(' ');
        }
        value = value.replaceAll(RegExp(r'^["\x27]|["\x27]$'), '');
        if (key == 'name') name = value;
        if (key == 'description') description = value;
      }
    }
  }
  if (name.isEmpty) {
    final h = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(text);
    name = h?.group(1)?.trim() ?? fallbackName;
  }
  if (text.isEmpty) return null;
  return Skill(id: newId(), name: name, description: description, instructions: text);
}
