import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'composer.dart';
import 'history_drawer.dart';
import 'message_view.dart';
import 'model_picker.dart';
import 'providers_screen.dart';
import 'skill_picker.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final GlobalKey<ComposerState> _composer = GlobalKey<ComposerState>();

  Conversation get _chat => store.current ?? store.newConversation();

  Future<void> _send(String text, List<Attachment> files) => engine.send(_chat, text, files);

  void _edit(ChatMessage m) {
    final c = _chat;
    final removed = engine.truncateFrom(c, m.id);
    if (removed != null) _composer.currentState?.load(removed.text, removed.attachments);
  }

  void _newChat({bool temporary = false}) {
    if (engine.busy) engine.stop();
    store.newConversation(temporary: temporary);
  }

  String _markdown(Conversation c) {
    final b = StringBuffer('# ${c.title}\n\n');
    for (final m in c.messages) {
      if (m.role == 'user') {
        b.writeln('**You:** ${m.text}');
        for (final a in m.attachments) {
          b.writeln('- 📎 ${a.name}');
        }
      } else if (m.role == 'assistant' && m.text.isNotEmpty) {
        b.writeln('**${m.model.isEmpty ? 'Assistant' : m.model}:** ${m.text}');
      }
      b.writeln();
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = _chat;
        final provider = store.providerById(c.providerId) ?? store.defaultProvider;
        final shown = c.messages.where((m) => m.role != 'tool').toList().reversed.toList();
        final running = engine.running == c;
        final lastAssistant = c.messages.lastIndexWhere((m) => m.role == 'assistant' && !m.error && m.text.isNotEmpty);
        return Scaffold(
          drawer: HistoryDrawer(onNewChat: _newChat),
          appBar: AppBar(
            title: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => showModelPicker(context, c),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                      child: Text(
                        c.model.isEmpty ? 'Choose a model' : c.model,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const Icon(Icons.expand_more_rounded, size: 20),
                  ]),
                  Text(
                    '${provider?.name ?? 'No provider'}${c.temporary ? ' · temporary' : ''}',
                    style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                  ),
                ]),
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'Skills',
                icon: Badge(
                  isLabelVisible: c.activeSkillIds.isNotEmpty,
                  label: Text('${c.activeSkillIds.length}'),
                  child: const Icon(Icons.bolt_rounded),
                ),
                onPressed: () => showSkillPicker(context, c),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'new') _newChat();
                  if (v == 'temp') _newChat(temporary: true);
                  if (v == 'copy') {
                    await Clipboard.setData(ClipboardData(text: _markdown(c)));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat copied as Markdown')));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'new', child: Text('New chat')),
                  PopupMenuItem(value: 'temp', child: Text('Temporary chat')),
                  PopupMenuItem(value: 'copy', child: Text('Copy chat as Markdown')),
                ],
              ),
            ],
          ),
          body: Column(children: [
            Expanded(
              child: c.messages.isEmpty
                  ? _Empty(hasProvider: store.providers.isNotEmpty, temporary: c.temporary)
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final m = shown[i];
                        final isLastAssistant = m.role == 'assistant' && c.messages.indexOf(m) == lastAssistant;
                        final streaming = running && identical(m, c.messages.last);
                        return MessageView(
                          key: ValueKey(m.id),
                          message: m,
                          streaming: streaming,
                          onRegenerate: isLastAssistant && !running ? () => engine.regenerate(c) : null,
                          onEdit: m.role == 'user' && !running ? () => _edit(m) : null,
                        );
                      },
                    ),
            ),
            Composer(key: _composer, onSend: _send, busy: running, onStop: engine.stop),
          ]),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasProvider, required this.temporary});

  final bool hasProvider;
  final bool temporary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(temporary ? Icons.visibility_off_outlined : Icons.chat_bubble_outline_rounded,
              size: 44, color: theme.colorScheme.primary),
          const SizedBox(height: 14),
          Text(
            hasProvider ? (temporary ? 'Temporary chat' : 'What can I help with?') : 'Add a provider to start',
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            hasProvider
                ? (temporary
                    ? 'Not saved, and memory is not used or written.'
                    : 'Attach photos, PDFs and documents with the + button.')
                : 'Paste an API key from OpenAI, Anthropic, Gemini, OpenRouter, Groq and more.',
            style: TextStyle(color: theme.hintColor),
            textAlign: TextAlign.center,
          ),
          if (!hasProvider) ...[
            const SizedBox(height: 18),
            FilledButton.icon(
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add provider'),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ProvidersScreen())),
            ),
          ],
        ]),
      ),
    );
  }
}
