import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/models.dart';
import '../tools/browser_service.dart';
import 'theme.dart';

/// Opens the shared browser. Called from anywhere: pages above the chat are closed first so the dock is visible.
void showBrowser(BuildContext context, {String address = '', bool full = true}) {
  Navigator.of(context).popUntil((r) => r.isFirst);
  BrowserService.instance.show(address: address.isEmpty ? (BrowserService.instance.url.value.isEmpty ? 'https://duckduckgo.com' : null) : address, full: full);
}

/// The browser panel that sits over the chat. The assistant works in it; the person can watch, take over, or hide it.
/// Put it inside a Stack that fills the chat page.
class DockLayer extends StatelessWidget {
  const DockLayer({super.key, required this.onAttach});

  final void Function(Attachment page) onAttach;

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: _panel(context)),
      Positioned(left: 10, right: 10, top: 8, child: const _AskBanner()),
    ]);
  }

  Widget _panel(BuildContext context) {
    final b = BrowserService.instance;
    return LayoutBuilder(builder: (context, box) {
      return ValueListenableBuilder<bool>(
        valueListenable: b.needed,
        builder: (context, needed, _) {
          if (!needed) return const SizedBox.shrink();
          return ValueListenableBuilder<DockMode>(
            valueListenable: b.mode,
            builder: (context, mode, _) {
              final view = WebViewWidget(key: b.viewKey, controller: b.controller);
              switch (mode) {
                case DockMode.hidden:
                  // Phone-sized and far off screen: pages lay out like on a phone, but nothing shows over the chat.
                  return Stack(children: [
                    Positioned(left: -5000, top: 0, width: 390, height: 780, child: ExcludeSemantics(child: IgnorePointer(child: view))),
                  ]);
                case DockMode.panel:
                  return Stack(children: [
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      height: box.maxHeight * 0.52,
                      child: _Card(view: view, full: false, onAttach: onAttach),
                    ),
                  ]);
                case DockMode.full:
                  return Stack(children: [
                    Positioned.fill(child: _Card(view: view, full: true, onAttach: onAttach)),
                  ]);
              }
            },
          );
        },
      );
    });
  }
}

/// The assistant's question while the browser is open: answer or press Done after acting in the page.
class _AskBanner extends StatefulWidget {
  const _AskBanner();

  @override
  State<_AskBanner> createState() => _AskBannerState();
}

class _AskBannerState extends State<_AskBanner> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _finish(AskRequest r, String answer) {
    if (!r.done.isCompleted) r.done.complete(answer);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final b = BrowserService.instance;
    final pal = paletteOf(context);
    return ValueListenableBuilder<AskRequest?>(
      valueListenable: b.ask,
      builder: (context, r, _) {
        if (r == null) return const SizedBox.shrink();
        return Material(
          elevation: 10,
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).brightness == Brightness.dark ? const Color(0xFF242426) : Colors.white,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 8),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(CupertinoIcons.hand_raised, size: 18, color: pal.accent),
                const SizedBox(width: 8),
                const Text('Needs you', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              ]),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(child: Text(r.question, style: const TextStyle(fontSize: 14.5, height: 1.35))),
              ),
              TextField(
                controller: _text,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(hintText: 'Answer (optional)', isDense: true, border: InputBorder.none, filled: false),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => _finish(r, 'The person cancelled. Stop the task.'), child: const Text('Cancel task')),
                FilledButton(
                  onPressed: () => _finish(r, _text.text.trim().isEmpty ? 'Done.' : _text.text.trim()),
                  child: const Text('Done'),
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.view, required this.full, required this.onAttach});

  final Widget view;
  final bool full;
  final void Function(Attachment page) onAttach;

  Future<void> _ask(BuildContext context) async {
    final b = BrowserService.instance;
    try {
      final text = await pageText(b.controller, 60000);
      final first = text.split('\n').first.trim();
      final title = first.isEmpty ? 'Web page' : first;
      onAttach(Attachment(
        id: newId(),
        name: title.length > 40 ? '${title.substring(0, 40)}…' : title,
        mime: 'text/plain',
        kind: AttachmentKind.text,
        text: text,
        size: text.length,
      ));
      b.hide();
    } catch (_) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not read this page')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = BrowserService.instance;
    final pal = paletteOf(context);
    final solid = Theme.of(context).brightness == Brightness.dark ? const Color(0xFF111111) : Colors.white;
    return Material(
      color: solid,
      elevation: full ? 0 : 12,
      borderRadius: BorderRadius.circular(full ? 0 : 18),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: full,
        bottom: false,
        child: Column(children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(children: [
              ValueListenableBuilder<bool>(
                valueListenable: b.canBack,
                builder: (context, v, _) =>
                    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(CupertinoIcons.chevron_back, size: 20), onPressed: v ? b.controller.goBack : null),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: b.canForward,
                builder: (context, v, _) => IconButton(
                    visualDensity: VisualDensity.compact, icon: const Icon(CupertinoIcons.chevron_forward, size: 20), onPressed: v ? b.controller.goForward : null),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => _editAddress(context),
                  child: Container(
                    height: 32,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(color: pal.bubble, borderRadius: BorderRadius.circular(10)),
                    child: ValueListenableBuilder<String>(
                      valueListenable: b.url,
                      builder: (context, u, _) => Text(
                        u.isEmpty ? 'Search or enter address' : (Uri.tryParse(u)?.host ?? u),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: u.isEmpty ? pal.secondary : null),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(CupertinoIcons.arrow_clockwise, size: 19), onPressed: b.controller.reload),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Ask about this page',
                icon: Icon(CupertinoIcons.chat_bubble_text, size: 20, color: pal.accent),
                onPressed: () => _ask(context),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(full ? CupertinoIcons.arrow_down_right_arrow_up_left : CupertinoIcons.arrow_up_left_arrow_down_right, size: 18),
                onPressed: () => b.mode.value = full ? DockMode.panel : DockMode.full,
              ),
              IconButton(visualDensity: VisualDensity.compact, icon: const Icon(CupertinoIcons.chevron_down, size: 20), onPressed: b.hide),
            ]),
          ),
          ValueListenableBuilder<int>(
            valueListenable: b.progress,
            builder: (context, p, _) => p > 0 && p < 100 ? LinearProgressIndicator(value: p / 100, minHeight: 2) : const SizedBox(height: 2),
          ),
          Expanded(child: view),
        ]),
      ),
    );
  }

  Future<void> _editAddress(BuildContext context) async {
    final b = BrowserService.instance;
    final controller = TextEditingController(text: b.url.value);
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Go to'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (v) => Navigator.pop(d, v),
          decoration: const InputDecoration(hintText: 'Search or enter address'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Go')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    var t = text.trim();
    final looksLikeUrl = !t.contains(' ') && (t.contains('.') || t.startsWith('http'));
    if (!looksLikeUrl) {
      t = 'https://duckduckgo.com/?q=${Uri.encodeQueryComponent(t)}';
    } else if (!t.startsWith('http')) {
      t = 'https://$t';
    }
    b.goTo(t);
  }
}
