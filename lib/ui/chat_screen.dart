import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'agent_timeline.dart';
import '../data/services.dart';
import 'browser_dock.dart';
import 'composer.dart';
import 'history_drawer.dart';
import 'message_view.dart';
import 'model_list.dart';
import 'model_picker.dart';
import '../tools/python_runtime.dart';
import 'plugins_screen.dart';
import 'project_screens.dart';
import 'steps_card.dart';
import 'providers_screen.dart';
import 'skill_picker.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final GlobalKey<ComposerState> _composer = GlobalKey<ComposerState>();

  Conversation get _chat => store.current ?? store.newConversation();

  Future<void> _send(String text, List<Attachment> files) => engine.send(_chat, text, files);

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
        final results = <String, String>{};
        for (final m in c.messages) {
          if (m.role == 'tool') results[m.toolCallId] = m.text;
        }
        // Replies that only call tools are folded into one steps card.
        final items = <Object>[];
        for (final m in c.messages) {
          if (m.role == 'tool') continue;
          final isStep = m.role == 'assistant' &&
              m.text.trim().isEmpty &&
              m.toolCalls.isNotEmpty &&
              m.sources.isEmpty &&
              m.note.isEmpty &&
              m.outputs.isEmpty &&
              !m.error;
          if (isStep && items.isNotEmpty && items.last is List<ChatMessage>) {
            (items.last as List<ChatMessage>).add(m);
          } else if (isStep) {
            items.add(<ChatMessage>[m]);
          } else {
            items.add(m);
          }
        }
        final shown = items.reversed.toList();
        ChatMessage? lastNonTool;
        for (final m in c.messages) {
          if (m.role != 'tool') lastNonTool = m;
        }
        final running = engine.running == c;
        final lastAssistant = c.messages.lastIndexWhere((m) => m.role == 'assistant' && !m.error && m.text.isNotEmpty);
        return Scaffold(
          drawer: HistoryDrawer(onNewChat: _newChat),
          appBar: AppBar(
            leading: Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(CupertinoIcons.line_horizontal_3),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
            title: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => showModelPicker(context, c),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(
                      c.model.isEmpty ? 'Choose a model' : shortModelName(c.model),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(CupertinoIcons.chevron_forward, size: 13, color: paletteOf(context).secondary),
                ]),
                Text(
                  '${provider?.name ?? 'No provider'}${c.temporary ? ' · temporary' : ''}',
                  style: TextStyle(fontSize: 11.5, color: paletteOf(context).secondary),
                ),
              ]),
            ),
            actions: [
              IconButton(
                tooltip: 'Skills',
                icon: Badge(
                  isLabelVisible: c.activeSkillIds.isNotEmpty,
                  label: Text('${c.activeSkillIds.length}'),
                  child: const Icon(CupertinoIcons.bolt),
                ),
                onPressed: () => showSkillPicker(context, c),
              ),
              IconButton(
                tooltip: 'New chat',
                icon: const Icon(CupertinoIcons.square_pencil),
                onPressed: _newChat,
              ),
              PopupMenuButton<String>(
                icon: const Icon(CupertinoIcons.ellipsis),
                onSelected: (v) async {
                  if (v == 'temp') _newChat(temporary: true);
                  if (v == 'browser') _composer.currentState?.openBrowser();
                  if (v == 'copy') {
                    await Clipboard.setData(ClipboardData(text: _markdown(c)));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat copied as Markdown')));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'temp', child: Text('Temporary chat')),
                  PopupMenuItem(value: 'browser', child: Text('Open browser')),
                  PopupMenuItem(value: 'copy', child: Text('Copy chat as Markdown')),
                ],
              ),
            ],
          ),
          body: Stack(children: [
            Column(children: [
            if (store.agentTask != null && store.agentTask!.conversationId == c.id)
              AgentTimelinePanel(task: store.agentTask!, registry: store.toolRegistry),
            Expanded(
              child: c.messages.isEmpty
                  ? _Empty(
                      hasProvider: store.providers.isNotEmpty,
                      temporary: c.temporary,
                      onSuggestion: (t) => _composer.currentState?.load(t, const <Attachment>[]),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.only(top: 8, bottom: 8),
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final item = shown[i];
                        if (item is List<ChatMessage>) {
                          return _StepGroup(
                            key: ValueKey('g${item.first.id}'),
                            messages: item,
                            resultOf: (id) => results[id],
                            live: running && identical(item.last, lastNonTool),
                          );
                        }
                        final m = item as ChatMessage;
                        final isLastAssistant = m.role == 'assistant' && c.messages.indexOf(m) == lastAssistant;
                        final streaming = running && identical(m, c.messages.last);
                        return MessageView(
                          key: ValueKey(m.id),
                          message: m,
                          resultOf: (id) => results[id],
                          streaming: streaming,
                          onRegenerate: isLastAssistant && !running ? () => engine.regenerate(c) : null,
                          onEditUser: m.role == 'user' && !running ? (t) => engine.editAndResend(c, m.id, t) : null,
                          onEditReply: m.role == 'assistant' && !running && !m.error
                              ? (t) {
                                  m.text = t;
                                  m.touch();
                                  store.scheduleSave(c);
                                }
                              : null,
                        );
                      },
                    ),
            ),
            if (c.projectId.isNotEmpty) ProjectBar(projectId: c.projectId),
            Composer(
              key: _composer,
              onSend: _send,
              busy: running,
              onStop: engine.stop,
              chat: c,
              onNewChat: _newChat,
              onSkills: () => showSkillPicker(context, c),
              onPlugins: () => Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => const PluginsScreen())),
              webOn: c.web,
              onToggleWeb: () {
                c.web = !c.web;
                store.scheduleSave(c);
                store.changed();
              },
            ),
            ]),
            Positioned.fill(child: DockLayer(onAttach: (page) => _composer.currentState?.addPage(page))),
            const PythonRuntimeMount(),
          ]),
        );
      },
    );
  }
}

/// Several tool-only replies shown as one list of steps.
class _StepGroup extends StatelessWidget {
  const _StepGroup({super.key, required this.messages, required this.resultOf, required this.live});

  final List<ChatMessage> messages;
  final String? Function(String id) resultOf;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(messages),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: StepsCard(calls: [for (final m in messages) ...m.toolCalls], resultOf: resultOf, live: live),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasProvider, required this.temporary, required this.onSuggestion});

  final bool hasProvider;
  final bool temporary;
  final void Function(String text) onSuggestion;

  static const List<(IconData, String)> _ideas = [
    (CupertinoIcons.search, 'What is the price of gold today?'),
    (CupertinoIcons.doc_text, 'Summarize the files I attach'),
    (CupertinoIcons.photo, 'Describe this photo'),
    (CupertinoIcons.chevron_left_slash_chevron_right, 'Explain a GitHub repo to me'),
  ];

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(temporary ? CupertinoIcons.eye_slash : CupertinoIcons.chat_bubble_2, size: 40, color: pal.secondary),
          const SizedBox(height: 16),
          Text(
            hasProvider ? (temporary ? 'Temporary chat' : 'What can I help with?') : 'Add a provider to start',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            hasProvider
                ? (temporary ? 'Not saved, and memory is not used or written.' : '')
                : 'Paste an API key from OpenAI, Anthropic, Gemini, OpenRouter, NVIDIA, Groq and more.',
            style: TextStyle(color: pal.secondary, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          if (!hasProvider)
            FilledButton.icon(
              icon: const Icon(CupertinoIcons.plus, size: 18),
              label: const Text('Add provider'),
              onPressed: () => Navigator.push(context, CupertinoPageRoute<void>(builder: (_) => const ProvidersScreen())),
            )
          else if (!temporary)
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              for (final (icon, text) in _ideas)
                GestureDetector(
                  onTap: () => onSuggestion(text),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(color: pal.field, borderRadius: BorderRadius.circular(18)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 16, color: pal.secondary),
                      const SizedBox(width: 8),
                      Flexible(child: Text(text, style: const TextStyle(fontSize: 14.5))),
                    ]),
                  ),
                ),
            ]),
        ]),
      ),
    );
  }
}
