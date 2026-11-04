import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../files/code_export.dart';

void openPreview(BuildContext context, String language, String code) {
  Navigator.push(
    context,
    CupertinoPageRoute<void>(fullscreenDialog: true, builder: (_) => CodePreviewPage(language: language, code: code)),
  );
}

/// Runs HTML or SVG from a code block in an isolated web view.
class CodePreviewPage extends StatefulWidget {
  const CodePreviewPage({super.key, required this.language, required this.code});

  final String language;
  final String code;

  @override
  State<CodePreviewPage> createState() => _CodePreviewPageState();
}

class _CodePreviewPageState extends State<CodePreviewPage> {
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(Colors.white)
    ..loadHtmlString(previewDocument(widget.language, widget.code));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        leading: IconButton(icon: const Icon(CupertinoIcons.xmark), onPressed: () => Navigator.pop(context)),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(CupertinoIcons.arrow_clockwise),
            onPressed: () => _web.loadHtmlString(previewDocument(widget.language, widget.code)),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(CupertinoIcons.doc_on_doc),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.code));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code copied')));
            },
          ),
          IconButton(
            tooltip: 'Download',
            icon: const Icon(CupertinoIcons.arrow_down_to_line),
            onPressed: () => saveCode(context, widget.language, widget.code),
          ),
        ],
      ),
      body: WebViewWidget(controller: _web),
    );
  }
}
