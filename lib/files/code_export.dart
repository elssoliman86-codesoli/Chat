import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

const Map<String, String> _extensions = {
  'dart': 'dart', 'python': 'py', 'py': 'py', 'javascript': 'js', 'js': 'js', 'typescript': 'ts', 'ts': 'ts',
  'tsx': 'tsx', 'jsx': 'jsx', 'html': 'html', 'htm': 'html', 'css': 'css', 'json': 'json', 'yaml': 'yaml', 'yml': 'yml',
  'markdown': 'md', 'md': 'md', 'kotlin': 'kt', 'kt': 'kt', 'java': 'java', 'bash': 'sh', 'sh': 'sh', 'shell': 'sh',
  'sql': 'sql', 'c': 'c', 'cpp': 'cpp', 'csharp': 'cs', 'cs': 'cs', 'go': 'go', 'rust': 'rs', 'rs': 'rs', 'php': 'php',
  'ruby': 'rb', 'rb': 'rb', 'swift': 'swift', 'xml': 'xml', 'svg': 'svg', 'toml': 'toml', 'ini': 'ini', 'csv': 'csv',
  'dockerfile': 'Dockerfile', 'gradle': 'gradle', 'lua': 'lua', 'r': 'r', 'powershell': 'ps1',
};

String extensionForLanguage(String language) => _extensions[language.toLowerCase()] ?? 'txt';

const Set<String> _previewLangs = {
  'html', 'htm', 'svg', 'markdown', 'md', 'json', 'csv', 'css', 'javascript', 'js', 'jsx', 'tsx', 'react', 'python', 'py',
};

/// Which languages the Preview button can show: the ones a web view can render, a JavaScript engine
/// can run, or (JavaScript, React/JSX, Python) that have an interpreter available in the app. Compiled
/// languages (Go, Java, C, Swift, and so on) have no such runtime on the phone, so they are not offered.
bool isPreviewable(String language, String code) {
  final l = language.toLowerCase();
  if (_previewLangs.contains(l)) return true;
  final head = code.trimLeft().toLowerCase();
  return l.isEmpty && (head.startsWith('<!doctype html') || head.startsWith('<html') || head.startsWith('<svg'));
}

const String _pageHead = '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    '<style>body{margin:16px;font:16px -apple-system,Roboto,sans-serif;color:#111;background:#fff}'
    'table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px;text-align:left}'
    'pre{background:#f4f4f5;padding:12px;border-radius:8px;overflow:auto;white-space:pre-wrap;word-break:break-word}'
    'code{font-family:monospace}img{max-width:100%}</style>';

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// Wraps a snippet so a WebView can show it: HTML and SVG run as-is, Markdown and JSON are rendered,
/// CSS and JavaScript run against a small demo page so the person can see the result.
String previewDocument(String language, String code) {
  final l = language.toLowerCase();
  final trimmed = code.trimLeft().toLowerCase();
  if (l == 'svg' || trimmed.startsWith('<svg')) {
    return '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#fff}'
        'svg{max-width:100%;height:auto}</style></head><body>$code</body></html>';
  }
  if (trimmed.startsWith('<!doctype') || trimmed.startsWith('<html')) return code;
  if (l == 'markdown' || l == 'md') {
    final html = md.markdownToHtml(code, extensionSet: md.ExtensionSet.gitHubWeb);
    return '<!doctype html><html><head>$_pageHead</head><body>$html</body></html>';
  }
  if (l == 'json') {
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(code));
    } catch (e) {
      pretty = '$code\n\n(Not valid JSON: $e)';
    }
    return '<!doctype html><html><head>$_pageHead</head><body><pre><code>${_esc(pretty)}</code></pre></body></html>';
  }
  if (l == 'csv') {
    final rows = const LineSplitter().convert(code).where((r) => r.trim().isNotEmpty).map((r) => r.split(',')).toList();
    final b = StringBuffer('<table>');
    for (var i = 0; i < rows.length; i++) {
      b.write('<tr>');
      for (final cell in rows[i]) {
        b.write(i == 0 ? '<th>${_esc(cell.trim())}</th>' : '<td>${_esc(cell.trim())}</td>');
      }
      b.write('</tr>');
    }
    b.write('</table>');
    return '<!doctype html><html><head>$_pageHead</head><body>$b</body></html>';
  }
  if (l == 'css') {
    return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>$code</style></head><body>'
        '<h1>Heading</h1><p>A paragraph of body text, so you can see how it looks with this style sheet applied.</p>'
        '<button>Button</button> <a href="#">A link</a>'
        '<div class="card" style="border:1px solid #ddd;padding:12px;margin-top:12px;border-radius:8px">A card</div>'
        '</body></html>';
  }
  if (l == 'jsx' || l == 'tsx' || l == 'react') {
    // Plain classic script, not data-type="module": some Android WebView versions silently refuse to
    // run the blob-URL ES-module script that Babel's auto-transform produces for type="module" sources,
    // which left the page blank with no error at all. A classic script does not have that problem.
    return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{margin:16px;font:14px/1.5 -apple-system,Roboto,sans-serif}#err{white-space:pre-wrap;font-family:monospace;'
        'color:#b00020;background:#fdecea;padding:10px;border-radius:8px;margin-top:10px}#loading{color:#888}</style>'
        '<script src="https://unpkg.com/react@18/umd/react.development.js"></script>'
        '<script src="https://unpkg.com/react-dom@18/umd/react-dom.development.js"></script>'
        '<script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>'
        '</head><body><div id="loading">Loading React…</div><div id="root"></div><div id="err"></div>'
        '<script>'
        'window.addEventListener("error",function(e){'
        'document.getElementById("loading").remove();'
        'document.getElementById("err").textContent="Error: "+(e.error&&e.error.message||e.message);'
        '});'
        'var _t=setTimeout(function(){'
        'var l=document.getElementById("loading");'
        'if(l) l.textContent="Still loading React/Babel from the network — check the internet connection.";'
        '},8000);'
        '</script>'
        '<script type="text/babel" data-presets="react,typescript">'
        'clearTimeout(_t);'
        'var _loading=document.getElementById("loading");if(_loading) _loading.remove();'
        'try{\n${code}\nif(typeof App!=="undefined"){ReactDOM.createRoot(document.getElementById("root")).render(<App/>);}'
        'else{document.getElementById("err").textContent="No App component found. Define: function App(){ ... }";}'
        '}catch(e){document.getElementById("err").textContent="Error: "+e.message;}'
        '</script></body></html>';
  }
  if (l == 'python' || l == 'py') {
    return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{margin:16px;font:14px/1.5 -apple-system,Roboto,sans-serif}#out{white-space:pre-wrap;font-family:monospace;'
        'background:#f4f4f5;padding:10px;border-radius:8px;margin-top:10px;min-height:20px}#status{color:#888}</style></head>'
        '<body><div id="status">Starting Python… (first time only, needs the internet)</div><div id="out"></div>'
        '<script src="https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js"></script><script>'
        '(async () => {'
        'const out=document.getElementById("out");const status=document.getElementById("status");'
        'window.addEventListener("error",function(e){status.textContent="Could not load Python: "+(e.error&&e.error.message||e.message);});'
        'const slow=setTimeout(function(){status.textContent="Still downloading Python (it is a few MB) — check the internet connection if this does not finish soon.";},10000);'
        'try {'
        'const py=await loadPyodide();'
        'clearTimeout(slow);'
        'py.setStdout({batched:(s)=>{out.textContent+=s+"\\n";}});'
        'py.setStderr({batched:(s)=>{out.textContent+=s+"\\n";}});'
        'status.textContent="Running…";'
        'try{ await py.runPythonAsync(${jsonEncode(code)}); status.textContent="Done."; }'
        'catch(e){ out.textContent+="\\n"+String(e); status.textContent="Error."; }'
        '} catch(e){ clearTimeout(slow); status.textContent="Could not start Python: "+String(e); }'
        '})();'
        '</script></body></html>';
  }
  if (l == 'javascript' || l == 'js') {
    return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{margin:16px;font:14px/1.5 -apple-system,Roboto,sans-serif}#out{white-space:pre-wrap;font-family:monospace;'
        'background:#f4f4f5;padding:10px;border-radius:8px;margin-top:10px;min-height:20px}</style></head>'
        '<body><div id="app"></div><div id="out"></div><script>'
        'const out=document.getElementById("out");const log=(...a)=>{out.textContent+=a.map(x=>typeof x==="object"?JSON.stringify(x):String(x)).join(" ")+"\\n";};'
        'console.log=log;console.error=log;console.warn=log;'
        'try{\n${code}\n}catch(e){log("Error: "+e.message);}'
        '</script></body></html>';
  }
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
