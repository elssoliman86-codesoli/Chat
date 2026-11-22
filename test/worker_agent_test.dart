import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/agents/file_locks.dart';
import 'package:omni_chat/agents/orchestrator.dart';
import 'package:omni_chat/agents/worker_agent.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/llm/llm.dart';

class _Script implements LlmClient {
  _Script(this.turns);
  final List<List<LlmEvent>> turns;
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Stream<LlmEvent> stream(LlmRequest request, AbortHandle abort) async* {
    requests.add(request);
    if (requests.length > turns.length) throw StateError('unexpected request ${requests.length}');
    for (final e in turns[requests.length - 1]) {
      yield e;
    }
    yield const LlmDone();
  }

  @override
  Future<List<String>> listModels() async => <String>[];

  @override
  Future<PingResult> ping(String model) async => const PingResult(200, '', 1);
}

ToolCall _call(String id, String name, Map<String, dynamic> args) => ToolCall(id: id, name: name, args: args);

const _specs = <ToolSpec>[
  ToolSpec(name: 'web_search', description: 'search', parameters: <String, dynamic>{}),
  ToolSpec(name: 'project_write', description: 'write', parameters: <String, dynamic>{}),
];

WorkerContext _ctx({FileLocks? locks, String main = 'the whole job'}) =>
    WorkerContext(worker: WorkerInfo('Worker 1', 'm'), abort: AbortHandle(), locks: locks ?? FileLocks(), mainTask: main, dependencyResults: const <String, String>{'Earlier': 'fact A'});

SubTask _task() => SubTask(id: 't', title: 'Research', prompt: 'Find the facts', files: ['notes.md']);

void main() {
  test('the brief keeps the main job, the worker\'s part and earlier results together', () {
    final b = workerBrief(_task(), _ctx());
    expect(b, contains('the whole job'));
    expect(b, contains('Your part: Research'));
    expect(b, contains('Find the facts'));
    expect(b, contains('notes.md'));
    expect(b, contains('fact A'));
  });

  test('a worker answers directly when it needs no tools', () async {
    final c = _Script([
      [const TextDelta('The result.'), const UsageEvent(outputTokens: 7)],
    ]);
    final ctx = _ctx();
    final out = await runWorkerAgent(task: _task(), ctx: ctx, client: c, model: 'm', tools: _specs, runTool: (call) async => 'x');
    expect(out, 'The result.');
    expect(ctx.worker.tokens, 7);
    expect(c.requests.single.system, kWorkerSystem);
  });

  test('a worker loops model → tool → model and returns the final text', () async {
    final c = _Script([
      [_wrap(_call('1', 'web_search', {'query': 'dart'}))],
      [const TextDelta('Found: dart is great.')],
    ]);
    final used = <String>[];
    final ctx = _ctx();
    final out = await runWorkerAgent(
      task: _task(),
      ctx: ctx,
      client: c,
      model: 'm',
      tools: _specs,
      runTool: (call) async {
        used.add(call.name);
        return 'search results';
      },
    );
    expect(out, 'Found: dart is great.');
    expect(used, ['web_search']);
    final second = c.requests[1].messages;
    expect(second.any((m) => m.role == 'tool' && m.text == 'search results'), isTrue);
    expect(second.any((m) => m.role == 'assistant' && m.toolCalls.isNotEmpty), isTrue);
  });

  test('tools that belong to the main assistant are refused for workers', () async {
    final c = _Script([
      [_wrap(_call('1', 'browser_open', {'url': 'x'}))],
      [const TextDelta('done without it')],
    ]);
    var ran = false;
    final out = await runWorkerAgent(task: _task(), ctx: _ctx(), client: c, model: 'm', tools: _specs, runTool: (call) async {
      ran = true;
      return 'x';
    });
    expect(ran, isFalse);
    expect(out, 'done without it');
    expect(c.requests[1].messages.last.text, contains('not available to workers'));
  });

  test('file writes by two workers are queued and the second one is flagged as a conflict', () async {
    final locks = FileLocks();
    final log = <String>[];
    Future<String> inner(ToolCall call) async {
      log.add('start ${call.id}');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      log.add('end ${call.id}');
      return 'Wrote a.txt';
    }

    final one = lockedToolRunner(locks, 'Worker 1', inner);
    final two = lockedToolRunner(locks, 'Worker 2', inner);
    await Future.wait([
      one(_call('A', 'project_write', {'files': [{'path': 'a.txt'}]})),
      two(_call('B', 'project_write', {'files': [{'path': 'a.txt'}]})),
    ]);
    expect(log, ['start A', 'end A', 'start B', 'end B']);
    expect(locks.conflicts.length, 1);
  });

  test('a worker that runs out of steps is asked to wrap up without tools', () async {
    final loop = [_wrap(_call('x', 'web_search', {'query': 'again'}))];
    final c = _Script([loop, loop, [const TextDelta('Here is what I have.')]]);
    final out = await runWorkerAgent(task: _task(), ctx: _ctx(), client: c, model: 'm', tools: _specs, runTool: (call) async => 'r', maxSteps: 2);
    expect(out, 'Here is what I have.');
    expect(c.requests.last.tools, isEmpty);
  });

  test('stopping the worker ends it with an error instead of running on', () async {
    final ctx = _ctx();
    ctx.abort.abort();
    final c = _Script([[const TextDelta('x')]]);
    await expectLater(runWorkerAgent(task: _task(), ctx: ctx, client: c, model: 'm', tools: _specs, runTool: (call) async => 'x'), throwsStateError);
  });

  test('integrated: the orchestrator runs several worker agents at once and aggregates their results', () async {
    final locks = FileLocks();
    final o = Orchestrator(
      mainTask: 'compare three things',
      config: const OrchestratorConfig(maxWorkers: 3, maxAgents: 8, mode: 'parallel', retries: 0, timeout: Duration(seconds: 10)),
      locks: locks,
      runner: (task, ctx) {
        final c = _Script([
          [_wrap(_call('${task.id}-1', 'web_search', {'query': task.title}))],
          [TextDelta('Result for ${task.title}')],
        ]);
        return runWorkerAgent(
          task: task,
          ctx: ctx,
          client: c,
          model: 'm',
          tools: _specs,
          runTool: (call) async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            return 'hits for ${call.args['query']}';
          },
        );
      },
    );
    final sw = Stopwatch()..start();
    final out = await o.run([
      for (final n in ['A', 'B', 'C']) SubTask(id: n, title: 'Topic $n', prompt: 'research $n'),
    ]);
    expect(out.allDone, isTrue);
    expect(out.report, contains('Result for Topic A'));
    expect(out.report, contains('Result for Topic C'));
    expect(sw.elapsedMilliseconds, lessThan(1500));
    expect(o.workers.length, 3);
    expect(o.workers.every((w) => w.tokens > 0), isTrue);
  });
}

LlmEvent _wrap(ToolCall c) => ToolCallDone(c);
