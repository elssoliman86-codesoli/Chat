import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/agents/trace.dart';
import 'package:omni_chat/core/models.dart';

ToolCall _call(String name, [Map<String, dynamic> args = const <String, dynamic>{}]) => ToolCall(id: name, name: name, args: args);

ExecutionTrace _trace() => ExecutionTrace(conversationId: 'c', request: 'build me a page', attachments: 1, model: 'm');

void main() {
  group('stages come from what really ran', () {
    test('tools are filed under the right stage', () {
      expect(stageForTool('set_plan', {}), Stage.planning);
      expect(stageForTool('web_search', {}), Stage.researching);
      expect(stageForTool('browser_click', {}), Stage.researching);
      expect(stageForTool('github_tree', {}), Stage.researching);
      expect(stageForTool('github_create_pr', {}), Stage.executing);
      expect(stageForTool('project_read', {}), Stage.files);
      expect(stageForTool('project_write', {}), Stage.executing);
      expect(stageForTool('project_check', {}), Stage.testing);
      expect(stageForTool('ask_advisor', {}), Stage.delegating);
      expect(stageForTool('run_parallel', {}), Stage.delegating);
      expect(stageForTool('termux_run', {'command': 'ls -la'}), Stage.executing);
      expect(stageForTool('termux_run', {'command': 'flutter test'}), Stage.testing);
      expect(stageForTool('python_run', {'code': 'import pytest\npytest.main()'}), Stage.testing);
      expect(stageForTool('something_new', {}), Stage.executing);
    });

    test('commands and file changes are read from the arguments', () {
      expect(commandOf('termux_run', {'command': 'git status'}), 'git status');
      expect(commandOf('python_run', {'code': 'print(1)'}), contains('print(1)'));
      expect(commandOf('web_search', {'query': 'x'}), '');
      final files = filesOf('project_write', {
        'files': [
          {'path': 'index.html', 'content': 'x'},
          {'path': 'app.js', 'content': 'y'},
        ]
      });
      expect(files.map((f) => f.path), ['index.html', 'app.js']);
      expect(filesOf('project_edit', {'path': 'a.txt'}).single.op, 'edited');
      expect(filesOf('project_delete', {'paths': ['x', 'y']}).length, 2);
      expect(filesOf('web_search', {}), isEmpty);
    });
  });

  group('a task from start to finish', () {
    test('a plain chat answer: understanding, then the answer', () {
      final t = _trace();
      t.log(Stage.analyzing, TraceKind.status, 'Read your message');
      t.passStart('m');
      expect(t.statusOf(Stage.understanding), StageStatus.running);
      expect(t.statusOf(Stage.finalizing), StageStatus.pending);
      t.passFirstToken(const Duration(milliseconds: 800));
      t.passEnd(hadTools: false, outputTokens: 120, took: const Duration(seconds: 3), summary: '120 tokens');
      t.end(TraceOutcome.completed);
      expect(t.eventsOf(Stage.finalizing).single.title, 'Wrote the answer');
      expect(t.eventsOf(Stage.understanding), isEmpty, reason: 'the only pass was the final answer');
      expect(t.visibleStages, [Stage.analyzing, Stage.finalizing], reason: 'stages that did not happen are not shown once it is over');
      expect(t.statusOf(Stage.finalizing), StageStatus.completed);
      expect(t.tokens, 120);
    });

    test('a task with tools moves through the stages and each reports its own state', () {
      final t = _trace();
      t.log(Stage.analyzing, TraceKind.status, 'Read your message');
      t.passStart('m');
      t.passEnd(hadTools: true, outputTokens: 40);
      final plan = t.toolStart(_call('set_plan', {'steps': []}), title: 'Planned');
      t.toolEnd(plan, result: 'ok', failed: false);
      final search = t.toolStart(_call('web_search', {'query': 'dart'}), title: 'Searched the web', detail: 'dart');
      expect(t.statusOf(Stage.researching), StageStatus.running);
      expect(t.statusOf(Stage.planning), StageStatus.completed);
      expect(t.stepsRunning, 1);
      t.toolEnd(search, result: 'results', failed: false);
      final write = t.toolStart(_call('project_write', {'files': [{'path': 'a.html'}]}), title: 'Wrote 1 file');
      t.toolEnd(write, result: 'Wrote a.html', failed: false);
      final cmd = t.toolStart(_call('termux_run', {'command': 'npm test'}), title: 'Ran a command');
      t.toolEnd(cmd, result: 'FAIL 1 test', failed: true);
      expect(t.statusOf(Stage.testing), StageStatus.failed);
      expect(t.statusOf(Stage.researching), StageStatus.completed);
      t.passStart('m');
      expect(t.eventsOf(Stage.reviewing).single.running, isTrue);
      t.passEnd(hadTools: false, outputTokens: 200);
      t.end(TraceOutcome.completed);

      expect(t.commands.single.command, 'npm test');
      expect(t.modifiedFiles.single.path, 'a.html');
      expect(t.toolsUsed['web_search']!.count, 1);
      expect(t.toolsUsed['termux_run']!.failed, 1);
      expect(t.problems.length, 1);
      expect(t.tokens, 240);
      expect(t.stepsCompleted, lessThan(t.stepsTotal), reason: 'the failed command is not a completed step');
      expect(t.summaryOf(Stage.researching), contains('web_search'));
      expect(t.summaryOf(Stage.testing), contains('1 failed'));
      expect(t.visibleStages.contains(Stage.delegating), isFalse);
    });

    test('waiting for the person shows as Waiting, and clears when they answer', () {
      final t = _trace();
      t.passStart('m');
      t.passEnd(hadTools: true);
      final ask = t.toolStart(_call('ask_user', {'question': 'which?'}), title: 'Asked you');
      expect(t.waiting, isTrue);
      expect(t.statusOf(Stage.understanding), StageStatus.waiting);
      expect(t.statusText, 'Waiting for you');
      t.toolEnd(ask, result: 'blue', failed: false);
      expect(t.waiting, isFalse);
      expect(t.statusOf(Stage.understanding), isNot(StageStatus.waiting));
    });

    test('Stop cancels whatever was running and keeps what finished', () {
      final t = _trace();
      t.passStart('m');
      t.passEnd(hadTools: true);
      final done = t.toolStart(_call('web_search', {'query': 'a'}), title: 'a');
      t.toolEnd(done, result: 'x', failed: false);
      final live = t.toolStart(_call('project_check'), title: 'checking');
      t.end(TraceOutcome.cancelled);
      expect(live.running, isFalse);
      expect(live.detail, contains('Stopped'));
      expect(t.statusOf(Stage.testing), StageStatus.cancelled);
      expect(t.statusOf(Stage.researching), StageStatus.completed);
      expect(t.statusText, 'Stopped');
      expect(t.running, isFalse);
    });

    test('a failed model request marks the task failed', () {
      final t = _trace();
      t.passStart('m');
      t.passEnd(hadTools: false, failed: true, summary: 'HTTP 401');
      t.log(Stage.finalizing, TraceKind.error, 'The model request failed', failed: true);
      t.end(TraceOutcome.failed, error: 'HTTP 401');
      expect(t.statusText, 'Failed');
      expect(t.problems, isNotEmpty);
    });

    test('workers and agents are counted for the overview', () {
      final t = _trace();
      t.setWorkers(agents: 3, workers: 2);
      expect(t.activeAgents, 3);
      expect(t.activeWorkers, 2);
      t.setWorkers(agents: 1);
      expect(t.agentsSeen, 3);
      t.end(TraceOutcome.completed);
      expect(t.activeAgents, 0);
      expect(t.activeWorkers, 0);
    });

    test('long tool output is shortened so memory stays flat', () {
      final t = _trace();
      final e = t.toolStart(_call('termux_run', {'command': 'cat big'}), title: 'x');
      t.toolEnd(e, result: 'a' * 100000, failed: false);
      expect(e.output.length, lessThan(5000));
    });

    test('the hub keeps only the latest traces', () {
      final hub = TraceHub();
      for (var i = 0; i < 40; i++) {
        hub.put(ExecutionTrace(conversationId: 'c$i', request: 'x'));
      }
      expect(hub.of('c0'), isNull);
      expect(hub.of('c39'), isNotNull);
    });
  });
}
