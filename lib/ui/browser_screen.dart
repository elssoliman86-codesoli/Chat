import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/models.dart';
import '../tools/browser_service.dart';
import 'theme.dart';

/// A small built-in browser. "Ask about this page" returns the page text as an attachment.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, this.url = ''});

  final String url;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final TextEditingController _address = TextEditingController(text: widget.url);
  late final WebViewController _web;
  int _progress = 0;
  bool _canBack = false;
  bool _canForward = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(browserUserAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageFinished: (u) async {
          _address.text = u;
          final back = await _web.canGoBack();
          final fwd = await _web.canGoForward();
          if (mounted) {
            setState(() {
              _canBack = back;
              _canForward = fwd;
            });
          }
        },
      ));
    _web.loadRequest(Uri.parse(widget.url.isEmpty ? 'https://duckduckgo.com' : widget.url));
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _go(String input) {
    var t = input.trim();
    if (t.isEmpty) return;
    final looksLikeUrl = !t.contains(' ') && (t.contains('.') || t.startsWith('http'));
    if (!looksLikeUrl) {
      t = 'https://duckduckgo.com/?q=${Uri.encodeQueryComponent(t)}';
    } else if (!t.startsWith('http')) {
      t = 'https://$t';
    }
    _web.loadRequest(Uri.parse(t));
    FocusScope.of(context).unfocus();
  }

  Future<void> _ask() async {
    setState(() => _busy = true);
    try {
      final text = await pageText(_web, 60000);
      final firstLine = text.split('\n').first.trim();
      final title = firstLine.isEmpty ? 'Web page' : firstLine;
      final attachment = Attachment(
        id: newId(),
        name: title.length > 40 ? '${title.substring(0, 40)}…' : title,
        mime: 'text/plain',
        kind: AttachmentKind.text,
        text: text,
        size: text.length,
      );
      if (mounted) Navigator.pop(context, attachment);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not read this page')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(CupertinoIcons.xmark), onPressed: () => Navigator.pop(context)),
        titleSpacing: 0,
        title: Container(
          height: 38,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(12)),
          child: TextField(
            controller: _address,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            autocorrect: false,
            onSubmitted: _go,
            style: const TextStyle(fontSize: 15),
            decoration: const InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintText: 'Search or enter address',
              prefixIcon: Icon(CupertinoIcons.lock_fill, size: 14),
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _progress > 0 && _progress < 100 ? LinearProgressIndicator(value: _progress / 100, minHeight: 2) : const SizedBox(height: 2),
        ),
      ),
      body: WebViewWidget(controller: _web),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: pal.separator, width: 0.5))),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            IconButton(icon: const Icon(CupertinoIcons.chevron_back), onPressed: _canBack ? _web.goBack : null),
            IconButton(icon: const Icon(CupertinoIcons.chevron_forward), onPressed: _canForward ? _web.goForward : null),
            IconButton(icon: const Icon(CupertinoIcons.arrow_clockwise), onPressed: _web.reload),
            const Spacer(),
            FilledButton.icon(
              onPressed: _busy ? null : _ask,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(CupertinoIcons.chat_bubble_text, size: 18),
              label: const Text('Ask about this page'),
            ),
          ]),
        ),
      ),
    );
  }
}
