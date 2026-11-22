import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/agents/file_locks.dart';
import 'package:omni_chat/agents/orchestrator.dart';

SubTask _t(String id, {List<String> deps = const <String>[], TaskPriority p = TaskPriority.normal, List<String> files = const <String>[], String? prompt}) =>
    SubTask(id: id, title: 'Task $id', prompt: prompt ?? 'do $id', dependsOn: deps, priority: p, files: files);

OrchestratorConfig _cfg({int workers = 2, int agents = 8, String mode = 'parallel', int retries = 1, Duration timeout = const Duration(seconds: 5)}) =>
    OrchestratorConfig(maxWorkers: workers, maxAgents: agents, mode: mode, retries: retries, timeout: timeout, retryDelay: const Duration(milliseconds: 5));

void main() {
  group('file locks', () {
    test('edits to the same file are queued, never interleaved', () async {
      final l = FileLocks();
      final log = <String>[];
      Future<void> edit(String who, String path) => l.synchronized(path, () async {
            log.add('$who start');
            await Future<void>.delayed(const Duration(milliseconds: 30));
            log.add('$who end');
          });
      await Future.wait([edit('a', 'src/x.dart'), edit('b', './SRC/x.dart'), edit('c', 'src/x.dart')]);
      expect(log, ['a start', 'a end', 'b start', 'b end', 'c start', 'c end']);
    });

    test('different files do not wait for each other', () async {
      final l = FileLocks();
      final sw = Stopwatch()..start();
      await Future.wait([
        l.synchronized('a', () => Future<void>.delayed(const Duration(milliseconds: 80))),
        l.synchronized('b', () => Future<void>.delayed(const Duration(milliseconds: 80))),
      ]);
      expect(sw.elapsedMilliseconds, lessThan(150));
    });

    test('a failing edit releases the file for the next one', () async {
      final l = FileLocks();
      await expectLater(l.synchronized('a', () async => throw StateError('x')), throwsStateError);
      expect(await l.synchronized('a', () async => 5), 5);
    });

    test('several files at once cannot deadlock', () async {
      final l = FileLocks();
      final done = await Future.wait([
        l.synchronizedAll(['a', 'b'], () async => 1),
        l.synchronizedAll(['b', 'a'], () async => 2),
      ]).timeout(const Duration(seconds: 2));
      expect(done, [1, 2]);
    });

    test('a second worker writing the same file is reported as a conflict', () {
      final l = FileLocks();
      l.recordWrite('a.txt', 'Worker 1');
      l.recordWrite('a.txt', 'Worker 1');
      expect(l.conflicts, isEmpty);
      l.recordWrite('A.txt', 'Worker 2');
      expect(l.conflicts.length, 1);
      expect(l.conflicts.single.first, 'Worker 1');
    });

    test('claims block overlapping tasks only', () {
      final l = FileLocks()..claim('t1', ['lib/a.dart']);
      expect(l.blocked('t2', ['lib/a.dart']), isTrue);
      expect(l.blocked('t2', ['lib/b.dart']), isFalse);
      expect(l.blocked('t1', ['lib/a.dart']), isFalse);
      l.release('t1');
      expect(l.blocked('t2', ['lib/a.dart']), isFalse);
    });
  });

  group('validation', () {
    test('duplicate tasks are merged, unknown or circular dependencies are rejected', () {
      final notes = <String>[];
      final out = Orchestrator.validate([_t('a'), SubTask(id: 'b', title: 'Task a', prompt: 'do a')], notes);
      expect(out.length, 1);
      expect(notes.single, contains('already'));
      expect(() => Orchestrator.validate([_t('a', deps: ['zzz'])], []), throwsArgumentError);
      expect(() => Orchestrator.validate([_t('a', deps: ['b']), _t('b', deps: ['a'])], []), throwsArgumentError);
      expect(() => Orchestrator.validate([_t('a'), _t('a', prompt: 'other')], []), throwsArgumentError);
    });

    test('the number of workers follows the settings and the job size', () {
      Orchestrator o(OrchestratorConfig c) => Orchestrator(runner: (t, c) async => '', config: c, mainTask: 'x');
      expect(o(_cfg(workers: 4, mode: 'parallel')).concurrencyFor(10), 4);
      expect(o(_cfg(workers: 4, mode: 'sequential')).concurrencyFor(10), 1);
      expect(o(_cfg(workers: 4, mode: 'auto')).concurrencyFor(2), 1);
      expect(o(_cfg(workers: 4, mode: 'auto')).concurrencyFor(8), 4);
      expect(o(_cfg(workers: 8, agents: 3, mode: 'parallel')).concurrencyFor(10), 2, reason: 'the main assistant counts as an agent');
      expect(o(_cfg(workers: 2, agents: 1, mode: 'parallel')).concurrencyFor(10), 1);
    });
  });

  group('running tasks', () {
    test('independent tasks run side by side, never more than the limit', () async {
      var live = 0;
      var peak = 0;
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(workers: 2),
        runner: (t, ctx) async {
          live++;
          if (live > peak) peak = live;
          await Future<void>.delayed(const Duration(milliseconds: 40));
          live--;
          return 'result ${t.id}';
        },
      );
      final out = await o.run([for (var i = 0; i < 6; i++) _t('t$i')]);
      expect(out.allDone, isTrue);
      expect(peak, 2);
      expect(out.tasks.map((t) => t.result), [for (var i = 0; i < 6; i++) 'result t$i']);
      expect(o.workers.length, 2);
    });

    test('sequential mode runs one at a time, in priority order', () async {
      final order = <String>[];
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(workers: 4, mode: 'sequential'),
        runner: (t, ctx) async {
          order.add(t.id);
          return t.id;
        },
      );
      await o.run([_t('low', p: TaskPriority.low), _t('norm'), _t('high', p: TaskPriority.high)]);
      expect(order, ['high', 'norm', 'low']);
    });

    test('a task waits for its dependencies and receives their results', () async {
      final seen = <String, Map<String, String>>{};
      final order = <String>[];
      final o = Orchestrator(
        mainTask: 'build a site',
        config: _cfg(workers: 3),
        runner: (t, ctx) async {
          order.add('start ${t.id}');
          seen[t.id] = ctx.dependencyResults;
          expect(ctx.mainTask, 'build a site');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          order.add('end ${t.id}');
          return 'out ${t.id}';
        },
      );
      await o.run([_t('c', deps: ['a', 'b']), _t('a'), _t('b')]);
      expect(order.indexOf('start c'), greaterThan(order.indexOf('end a')));
      expect(order.indexOf('start c'), greaterThan(order.indexOf('end b')));
      expect(seen['c'], {'Task a': 'out a', 'Task b': 'out b'});
    });

    test('two tasks that change the same file never run together', () async {
      var live = 0;
      var peak = 0;
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(workers: 3),
        runner: (t, ctx) async {
          live++;
          if (live > peak) peak = live;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          live--;
          return t.id;
        },
      );
      final out = await o.run([_t('a', files: ['x.txt']), _t('b', files: ['./X.txt']), _t('c', files: ['y.txt'])]);
      expect(out.allDone, isTrue);
      expect(peak, 2, reason: 'a and b share a file, c can run beside one of them');
    });

    test('a failed task is retried, then succeeds', () async {
      var calls = 0;
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(retries: 2),
        runner: (t, ctx) async {
          calls++;
          if (calls < 3) throw StateError('flaky');
          return 'ok';
        },
      );
      final out = await o.run([_t('a')]);
      expect(out.allDone, isTrue);
      expect(out.tasks.single.attempts, 3);
    });

    test('a task that keeps failing is reported, and tasks that needed it are not run', () async {
      final ran = <String>[];
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(retries: 1),
        runner: (t, ctx) async {
          ran.add(t.id);
          if (t.id == 'a') throw StateError('boom');
          return 'ok ${t.id}';
        },
      );
      final out = await o.run([_t('a'), _t('b', deps: ['a']), _t('c')]);
      expect(out.tasks.firstWhere((t) => t.id == 'a').state, TaskState.failed);
      expect(out.tasks.firstWhere((t) => t.id == 'b').state, TaskState.cancelled);
      expect(out.tasks.firstWhere((t) => t.id == 'c').state, TaskState.done);
      expect(ran.contains('b'), isFalse);
      expect(ran.where((x) => x == 'a').length, 2, reason: 'one retry');
      expect(out.report, contains('FAILED'));
      expect(out.report, contains('boom'));
      expect(o.workers.any((w) => w.state == WorkerState.failed), isTrue);
    });

    test('a stuck worker is stopped by the timeout', () async {
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(retries: 0, timeout: const Duration(milliseconds: 80)),
        runner: (t, ctx) => Completer<String>().future,
      );
      final out = await o.run([_t('a')]);
      expect(out.tasks.single.state, TaskState.failed);
      expect(out.tasks.single.error, contains('Timed out'));
    });

    test('cancel stops everything at once, even workers that ignore it', () async {
      final o = Orchestrator(mainTask: 'x', config: _cfg(workers: 2), runner: (t, ctx) => Completer<String>().future);
      final run = o.run([_t('a'), _t('b'), _t('c')]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(o.activeWorkers, 2);
      o.cancel();
      final out = await run.timeout(const Duration(seconds: 2));
      expect(out.cancelled, isTrue);
      expect(out.tasks.every((t) => t.state == TaskState.cancelled), isTrue);
      expect(o.activeWorkers, 0);
      expect(o.workers.every((w) => w.state == WorkerState.stopped), isTrue);
    });

    test('files changed by two workers show up in the report', () async {
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(workers: 2),
        runner: (t, ctx) async {
          ctx.locks.recordWrite('shared.txt', ctx.worker.name);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return 'wrote';
        },
      );
      final out = await o.run([_t('a'), _t('b')]);
      expect(out.conflicts.length, 1);
      expect(out.report, contains('shared.txt'));
    });

    test('worker cards track state, tokens and the last event', () async {
      final events = <String>[];
      final o = Orchestrator(
        mainTask: 'x',
        config: _cfg(workers: 1),
        runner: (t, ctx) async {
          ctx.addTokens(42);
          ctx.event('Searching the web');
          expect(ctx.worker.state, WorkerState.active);
          return 'done';
        },
      )..onEvent = (w, text, failed) => events.add('$w: $text');
      await o.run([_t('a')]);
      final w = o.workers.single;
      expect(w.state, WorkerState.completed);
      expect(w.tokens, 42);
      expect(w.taskTitle, 'Task a');
      expect(w.result, 'done');
      expect(w.elapsed, isNot(Duration.zero));
      expect(events.first, contains('Started'));
      expect(events.last, contains('Finished'));
    });

    test('running twice at once is refused', () async {
      final o = Orchestrator(mainTask: 'x', config: _cfg(), runner: (t, ctx) async => 'x');
      final first = o.run([_t('a')]);
      expect(() => o.run([_t('b')]), throwsStateError);
      await first;
    });
  });
}
