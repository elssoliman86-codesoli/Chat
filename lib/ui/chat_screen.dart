import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../data/services.dart';
import 'browser_dock.dart';
import 'composer.dart';
import 'history_drawer.dart';
import 'message_view.dart';
import 'model_list.dart';
import 'model_picker.dart';
import '../tools/python_runtime.dart';
import 'plan_banner.dart';
import 'plugins_screen.dart';
import 'project_screens.dart';
import 'steps_card.dart';
import 'thinking/thinking_panel.dart';
import 'providers_screen.dart';
import 'skill_picker.dart';
import 'glass/glass.dart';
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
        final toolMsgs = <String, ChatMessage>{};
        for (final m in c.messages) {
          if (m.role == 'tool') {
            results[m.toolCallId] = m.text;
            toolMsgs[m.toolCallId] = m;
          }
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
        // The plan and skill-load banners are pinned above the chat (not the Steps card at the bottom),
        // and only reflect the current turn: everything since the person's last message.
        final lastUserIdx = c.messages.lastIndexWhere((m) => m.role == 'user');
        final turnMessages = lastUserIdx >= 0 ? c.messages.sublist(lastUserIdx + 1) : c.messages;
        final skillCall = latestSkillCall(turnMessages);
        return Scaffold(
          drawer: HistoryDrawer(onNewChat: _newChat),
          appBar: AppBar(
            leadingWidth: 56,
            leading: Builder(
              builder: (ctx) => Center(
                child: GlassIconButton(icon: CupertinoIcons.line_horizontal_3, tooltip: 'Chats', size: 38, onPressed: () => Scaffold.of(ctx).openDrawer()),
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
                  '${provider?.name ?? 'No provider'}${c.temporary ? ' · temporary' : ''}${c.longTask ? ' · long tasks' : ''}',
                  style: TextStyle(fontSize: 11.5, color: paletteOf(context).secondary),
                ),
              ]),
            ),
            actions: [
              Badge(
                isLabelVisible: c.activeSkillIds.isNotEmpty,
                label: Text('${c.activeSkillIds.length}'),
                child: GlassIconButton(icon: CupertinoIcons.bolt, tooltip: 'Skills', size: 36, active: c.activeSkillIds.isNotEmpty, onPressed: () => showSkillPicker(context, c)),
              ),
              const SizedBox(width: 6),
              GlassIconButton(icon: CupertinoIcons.square_pencil, tooltip: 'New chat', size: 36, onPressed: _newChat),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(CupertinoIcons.ellipsis, size: GlassTokens.iconMd),
                onSelected: (v) async {
                  if (v == 'temp') _newChat(temporary: true);
                  if (v == 'long') {
                    c.longTask = !c.longTask;
                    store.scheduleSave(c);
                    store.changed();
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(
                        content: Text(c.longTask
                            ? 'Long tasks on — the assistant keeps going until the whole job is done'
                            : 'Long tasks off'),
                      ));
                  }
                  if (v == 'team') {
                    c.assistChats = !c.assistChats;
                    store.scheduleSave(c);
                    store.changed();
                    final linked = store.settings.webChatPrimary.trim().isNotEmpty;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(
                        content: Text(!c.assistChats
                            ? 'Assistant chats off'
                            : (linked
                                ? 'Assistant chats on — design and build tasks go through your chat websites in the background'
                                : 'Assistant chats on, but no link is set yet: Settings → Plugins → Web chat team')),
                      ));
                  }
                  if (v == 'thinking') {
                    store.settings.thinkingPanel = !store.settings.thinkingPanel;
                    store.saveSettings();
                    store.changed();
                  }
                  if (v == 'browser') _composer.currentState?.openBrowser();
                  if (v == 'winscan') {
                    if (engine.busy) {
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(const SnackBar(content: Text('Wait for the current task to finish (or stop it), then start the scan')));
                    } else {
                      // Make sure the live view is on so the scan can be watched.
                      if (!store.settings.thinkingPanel) {
                        store.settings.thinkingPanel = true;
                        store.saveSettings();
                      }
                      engine.startWindowsScan(c);
                    }
                  }
                  if (v == 'copy') {
                    await Clipboard.setData(ClipboardData(text: _markdown(c)));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chat copied as Markdown')));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'temp', child: Text('Temporary chat')),
                  PopupMenuItem(
                    value: 'long',
                    child: Row(children: [
                      const Expanded(child: Text('Long tasks')),
                      if (c.longTask) const Icon(CupertinoIcons.checkmark_alt, size: 18),
                    ]),
                  ),
                  PopupMenuItem(
                    value: 'team',
                    child: Row(children: [
                      const Expanded(child: Text('Assistant chats')),
                      if (c.assistChats) const Icon(CupertinoIcons.checkmark_alt, size: 18),
                    ]),
                  ),
                  PopupMenuItem(
                    value: 'thinking',
                    child: Row(children: [
                      const Expanded(child: Text('Thinking panel')),
                      if (store.settings.thinkingPanel) const Icon(CupertinoIcons.checkmark_alt, size: 18),
                    ]),
                  ),
                  const PopupMenuItem(value: 'browser', child: Text('Open browser')),
                  PopupMenuItem(
                    value: 'winscan',
                    child: Row(children: [
                      const Icon(CupertinoIcons.shield_lefthalf_fill, size: 18),
                      const SizedBox(width: 10),
                      const Expanded(child: Text('Full Windows scan')),
                    ]),
                  ),
                  const PopupMenuItem(value: 'copy', child: Text('Copy chat as Markdown')),
                ],
              ),
            ],
          ),
          body: Stack(children: [
            Column(children: [
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
                            msgOf: (id) => toolMsgs[id],
                            live: running && identical(item.last, lastNonTool),
                          );
                        }
                        final m = item as ChatMessage;
                        final isLastAssistant = m.role == 'assistant' && c.messages.indexOf(m) == lastAssistant;
                        // lastAssistant above skips error/empty replies on purpose (nothing to regenerate from), so
                        // it is never true for the one error bubble Continue needs — check the raw last message instead.
                        final isLastMessage = c.messages.isNotEmpty && identical(m, c.messages.last);
                        final streaming = running && identical(m, c.messages.last);
                        return MessageView(
                          key: ValueKey(m.id),
                          message: m,
                          resultOf: (id) => results[id],
                          msgOf: (id) => toolMsgs[id],
                          streaming: streaming,
                          onRegenerate: isLastAssistant && !running ? () => engine.regenerate(c) : null,
                          onContinue: isLastMessage && !running && m.error ? () => engine.continueReply(c) : null,
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
            ThinkingPanel(conversationId: c.id),
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
            // The banners and the plan badge come BEFORE the browser dock in this Stack so the dock draws on
            // top of them: its own toolbar (back/forward/reload and the arrow that collapses it) sits at
            // the very top of the screen, and anything drawn after it used to cover that arrow.
            if ((c.turnInProgress && !running) || skillCall != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (c.turnInProgress && !running)
                    InterruptedBanner(key: ValueKey('interrupted-${c.id}'), onContinue: () => engine.continueReply(c)),
                  if (skillCall != null)
                    SkillLoadBanner(
                      key: ValueKey('skill-${skillCall.id}'),
                      name: (skillCall.args['name'] ?? '').toString(),
                      result: results[skillCall.id],
                    ),
                ]),
              ),
            if (c.planSteps.isNotEmpty)
              Positioned(top: 8, right: 10, child: PlanBadge(steps: c.planSteps, current: c.planCurrent)),
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
  const _StepGroup({super.key, required this.messages, required this.resultOf, required this.msgOf, required this.live});

  final List<ChatMessage> messages;
  final String? Function(String id) resultOf;
  final ChatMessage? Function(String id) msgOf;
  final bool live;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(messages),
      builder: (context, _) {
        final calls = stepsOnly([for (final m in messages) ...m.toolCalls]);
        if (calls.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: StepsCard(calls: calls, resultOf: resultOf, msgOf: msgOf, live: live),
        );
      },
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
                    decoration: BoxDecoration(
                      color: pal.field,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: pal.rim, width: GlassTokens.stroke),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 16, color: pal.accent),
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
