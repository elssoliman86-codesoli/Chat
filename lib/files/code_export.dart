import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const Map<String, String> _extensions = {
  'dart': 'dart', 'python': 'py', 'py': 'py', 'javascript': 'js', 'js': 'js', 'typescript': 'ts', 'ts': 'ts',
  'tsx': 'tsx', 'jsx': 'jsx', 'html': 'html', 'htm': 'html', 'css': 'css', 'json': 'json', 'yaml': 'yaml', 'yml': 'yml',
  'markdown': 'md', 'md': 'md', 'kotlin': 'kt', 'kt': 'kt', 'java': 'java', 'bash': 'sh', 'sh': 'sh', 'shell': 'sh',
  'sql': 'sql', 'c': 'c', 'cpp': 'cpp', 'csharp': 'cs', 'cs': 'cs', 'go': 'go', 'rust': 'rs', 'rs': 'rs', 'php': 'php',
  'ruby': 'rb', 'rb': 'rb', 'swift': 'swift', 'xml': 'xml', 'svg': 'svg', 'toml': 'toml', 'ini': 'ini', 'csv': 'csv',
  'dockerfile': 'Dockerfile', 'gradle': 'gradle', 'lua': 'lua', 'r': 'r', 'powershell': 'ps1',
};

String extensionForLanguage(String language) => _extensions[language.toLowerCase()] ?? 'txt';

/// HTML and SVG can be shown in the preview page.
bool isPreviewable(String language, String code) {
  final l = language.toLowerCase();
  if (l == 'html' || l == 'htm' || l == 'svg') return true;
  final head = code.trimLeft().toLowerCase();
  return l.isEmpty && (head.startsWith('<!doctype html') || head.startsWith('<html') || head.startsWith('<svg'));
}

/// Wraps a snippet so a WebView can show it.
String previewDocument(String language, String code) {
  final l = language.toLowerCase();
  final trimmed = code.trimLeft().toLowerCase();
  if (l == 'svg' || trimmed.startsWith('<svg')) {
    return '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#fff}'
        'svg{max-width:100%;height:auto}</style></head><body>$code</body></html>';
  }
  if (trimmed.startsWith('<!doctype') || trimmed.startsWith('<html')) return code;
  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      '</head><body>$code</body></html>';
}

/// Lets the person choose where to save the code. Shows a short message about the result.
Future<void> saveCode(BuildContext context, String language, String code) async {
  final messenger = ScaffoldMessenger.of(context);
  final ext = extensionForLanguage(language);
  final name = ext == 'Dockerfile' ? 'Dockerfile' : 'code.$ext';
  try {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save code',
      fileName: name,
      bytes: Uint8List.fromList(utf8.encode(code)),
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(path == null ? 'Not saved' : 'Saved $name')));
  } catch (e) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not save the file')));
  }
}
