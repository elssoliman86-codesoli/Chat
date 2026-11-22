import 'dart:async';

import '../core/models.dart';
import '../llm/llm.dart';
import '../llm/resilient.dart';
import 'file_locks.dart';
import 'orchestrator.dart';
import 'trace.dart' show filesOf;

/// The tools a worker may use. Everything that works on one shared thing — the single built-in browser, the
/// Python runtime, the terminal, asking the person a question — stays with the main assistant, so workers can
/// run side by side without fighting over it.
const Set<String> kWorkerTools = <String>{
  'web_search',
  'fetch_page',
  'image_search',
  'project_read',
  'project_list',
  'project_search',
  'project_write',
  'project_edit',
  'github_file',
  'github_tree',
  'github_search',
  'github_repo',
};

const Set<String> _writeTools = <String>{'project_write', 'project_edit', 'project_delete', 'project_move'};

const String kWorkerSystem = 'You are a worker agent. A main assistant split a bigger job into parts and gave you one of them. '
    'Do only your part, using the tools you have, and do it properly. You cannot ask the person questions: if you are blocked, '
    'say exactly what blocked you. When you are done, reply with a short, concrete result for the main assistant: what you found '
    'or did, the key facts or text it needs, and the files you changed. Do not restate your instructions.';

String workerBrief(SubTask task, WorkerContext ctx) {
  final b = StringBuffer()
    ..writeln('The whole job (for context only — you are NOT asked to do all of it):')
    ..writeln(ctx.mainTask.trim().isEmpty ? '(not given)' : ctx.mainTask.trim())
    ..writeln()
    ..writeln('Your part: ${task.title}')
    ..writeln(task.prompt.trim());
  if (task.files.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Files you own for this part: ${task.files.join(', ')}. Other workers will not edit them while you work.');
  }
  if (ctx.dependencyResults.isNotEmpty) {
    b
      ..writeln()
      ..writeln('Results of the parts you depend on:');
    ctx.dependencyResults.forEach((title, result) {
      b
        ..writeln('--- $title ---')
        ..writeln(result.trim());
    });
  }
  return b.toString().trim();
}

/// Wraps a tool runner so that file changes by different workers are queued per file and recorded.
Future<String> Function(ToolCall) lockedToolRunner(FileLocks locks, String owner, Future<String> Function(ToolCall) inner) {
  return (call) async {
    if (!_writeTools.contains(call.name)) return inner(call);
    final paths = filesOf(call.name, call.args).map((f) => f.path).toList();
    if (paths.isEmpty) return inner(call);
    return locks.synchronizedAll(paths, () async {
      final out = await inner(call);
      final failed = out.startsWith('Tool failed') || out.toLowerCase().startsWith('error');
      if (!failed) {
        for (final p in paths) {
          locks.recordWrite(p, owner);
        }
      }
      return out;
    });
  };
}

/// Runs one worker: a small agent loop (model → tools → model…) on its own conversation, reporting what it
/// does to its card, until it has a final result.
Future<String> runWorkerAgent({
  required SubTask task,
  required WorkerContext ctx,
  required LlmClient client,
  required String model,
  required List<ToolSpec> tools,
  required Future<String> Function(ToolCall call) runTool,
  int maxSteps = 8,
  double? temperature,
  String reasoningEffort = '',
}) async {
  final run = lockedToolRunner(ctx.locks, ctx.worker.name, runTool);
  final messages = <ChatMessage>[ChatMessage(role: 'user', text: workerBrief(task, ctx))];

  Future<(String, List<ToolCall>)> ask(List<ToolSpec> offered) async {
    final out = StringBuffer();
    final calls = <ToolCall>[];
    var reported = 0;
    var wrote = false;
    final request = LlmRequest(
      system: kWorkerSystem,
      messages: List<ChatMessage>.of(messages),
      model: model,
      tools: offered,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );
    await for (final e in resilientStream(client: client, request: request, abort: ctx.abort)) {
      if (e is TextDelta) {
        out.write(e.text);
        if (!wrote) {
          wrote = true;
          ctx.event('Writing…');
        }
      } else if (e is ToolCallDone) {
        calls.add(e.call);
      } else if (e is UsageEvent && e.outputTokens != null) {
        final n = e.outputTokens!;
        if (n > reported) {
          ctx.addTokens(n - reported);
          reported = n;
        }
      }
    }
    if (reported == 0) ctx.addTokens((out.length / 4).ceil());
    return (out.toString(), calls);
  }

  for (var step = 0; step < maxSteps; step++) {
    if (ctx.abort.aborted) throw StateError('Stopped');
    ctx.event(step == 0 ? 'Thinking about the task…' : 'Reading the tool results…');
    final (text, calls) = await ask(tools);
    if (calls.isEmpty) return text.trim();
    messages.add(ChatMessage(role: 'assistant', text: text, toolCalls: calls));
    for (final call in calls) {
      if (ctx.abort.aborted) throw StateError('Stopped');
      if (!kWorkerTools.contains(call.name) || !tools.any((t) => t.name == call.name)) {
        messages.add(ChatMessage(role: 'tool', text: 'Tool "${call.name}" is not available to workers.', toolCallId: call.id, toolName: call.name, failed: true));
        continue;
      }
      ctx.event('Using ${call.name}…');
      final result = await run(call);
      messages.add(ChatMessage(role: 'tool', text: result, toolCallId: call.id, toolName: call.name));
    }
  }
  // Out of steps: make it hand over what it has.
  messages.add(ChatMessage(role: 'user', text: 'Stop using tools now and give your final result for the main assistant, based on what you have.', auto: true));
  ctx.event('Wrapping up…');
  final (text, _) = await ask(const <ToolSpec>[]);
  return text.trim();
}
