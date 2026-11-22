import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../llm/llm.dart' show AbortHandle;
import 'file_locks.dart';

enum TaskPriority { low, normal, high }

enum TaskState { queued, running, done, failed, cancelled }

enum WorkerState { idle, active, waiting, completed, failed, stopped }

String workerStateLabel(WorkerState s) => switch (s) {
      WorkerState.idle => 'Idle',
      WorkerState.active => 'Active',
      WorkerState.waiting => 'Waiting',
      WorkerState.completed => 'Completed',
      WorkerState.failed => 'Failed',
      WorkerState.stopped => 'Stopped',
    };

TaskPriority priorityFrom(Object? v, [TaskPriority fallback = TaskPriority.normal]) {
  final s = (v ?? '').toString().toLowerCase();
  return switch (s) {
    'high' || 'urgent' => TaskPriority.high,
    'low' => TaskPriority.low,
    'normal' || 'medium' => TaskPriority.normal,
    _ => fallback,
  };
}

/// One piece of a bigger task, handed to a worker.
class SubTask {
  SubTask({
    required this.id,
    required this.title,
    required this.prompt,
    this.dependsOn = const <String>[],
    this.priority = TaskPriority.normal,
    this.files = const <String>[],
  });

  final String id;
  final String title;
  final String prompt;
  final List<String> dependsOn;
  final TaskPriority priority;

  /// Files the task means to change; the scheduler never runs two tasks that share one at the same time.
  final List<String> files;

  TaskState state = TaskState.queued;
  int attempts = 0;
  String result = '';
  String error = '';
  String worker = '';
  DateTime? startedAt;
  DateTime? endedAt;

  String get key => '${title.trim().toLowerCase()}|${prompt.trim().toLowerCase()}';
}

/// A worker slot: the card in the Multi-Agent Monitor.
class WorkerInfo extends ChangeNotifier {
  WorkerInfo(this.name, this.model);

  final String name;
  String model;
  String taskTitle = '';
  WorkerState state = WorkerState.idle;
  DateTime? startedAt;
  DateTime? endedAt;
  int tokens = 0;
  String lastEvent = '';
  String result = '';
  int tasksDone = 0;

  Duration get elapsed => startedAt == null ? Duration.zero : (endedAt ?? DateTime.now()).difference(startedAt!);

  void begin(SubTask t) {
    taskTitle = t.title;
    state = WorkerState.active;
    startedAt = DateTime.now();
    endedAt = null;
    result = '';
    lastEvent = 'Started';
    notifyListeners();
  }

  void event(String text) {
    lastEvent = text;
    notifyListeners();
  }

  void waiting(String why) {
    state = WorkerState.waiting;
    lastEvent = why;
    notifyListeners();
  }

  void resume() {
    if (state == WorkerState.waiting) state = WorkerState.active;
    notifyListeners();
  }

  void addTokens(int n) {
    tokens += n;
    notifyListeners();
  }

  void finish(WorkerState s, {String result = '', String note = ''}) {
    state = s;
    endedAt = DateTime.now();
    if (result.isNotEmpty) this.result = result;
    if (note.isNotEmpty) lastEvent = note;
    if (s == WorkerState.completed) tasksDone++;
    notifyListeners();
  }

  void idle() {
    state = WorkerState.idle;
    notifyListeners();
  }
}

/// What a worker is given while it runs a task.
class WorkerContext {
  WorkerContext({required this.worker, required this.abort, required this.locks, required this.mainTask, required this.dependencyResults});

  final WorkerInfo worker;
  final AbortHandle abort;
  final FileLocks locks;

  /// The person's overall request, so a subtask never loses sight of what the whole job is for.
  final String mainTask;

  /// Results of the tasks this one depends on, by title.
  final Map<String, String> dependencyResults;

  void event(String text) => worker.event(text);
  void addTokens(int n) => worker.addTokens(n);
}

typedef WorkerRunner = Future<String> Function(SubTask task, WorkerContext ctx);

class _Stopped implements Exception {
  const _Stopped();
}

class OrchestratorConfig {
  const OrchestratorConfig({
    this.maxWorkers = 2,
    this.maxAgents = 4,
    this.mode = 'auto',
    this.timeout = const Duration(seconds: 180),
    this.retries = 1,
    this.defaultPriority = TaskPriority.normal,
    this.retryDelay = const Duration(milliseconds: 800),
  });

  final int maxWorkers;

  /// Agents allowed at once, counting the main assistant (which is one of them).
  final int maxAgents;

  /// 'sequential' (one at a time), 'parallel' (as many as allowed) or 'auto' (sized to the job).
  final String mode;
  final Duration timeout;
  final int retries;
  final TaskPriority defaultPriority;
  final Duration retryDelay;
}

class OrchestratorOutcome {
  OrchestratorOutcome(this.tasks, this.conflicts, this.cancelled);

  final List<SubTask> tasks;
  final List<FileConflict> conflicts;
  final bool cancelled;

  int get done => tasks.where((t) => t.state == TaskState.done).length;
  int get failed => tasks.where((t) => t.state == TaskState.failed).length;
  int get skipped => tasks.where((t) => t.state == TaskState.cancelled).length;
  bool get allDone => done == tasks.length;

  /// One report for the main assistant: every task's result in order, then what went wrong.
  String get report {
    final b = StringBuffer('Ran ${tasks.length} task${tasks.length == 1 ? '' : 's'} with workers: $done done');
    if (failed > 0) b.write(', $failed failed');
    if (skipped > 0) b.write(', $skipped not run');
    b.writeln('.');
    for (final t in tasks) {
      b.writeln();
      b.writeln('## ${t.title} — ${switch (t.state) {
        TaskState.done => 'done',
        TaskState.failed => 'FAILED',
        TaskState.cancelled => cancelled ? 'stopped' : 'not run',
        _ => 'not finished',
      }}${t.worker.isEmpty ? '' : ' (${t.worker})'}');
      if (t.state == TaskState.done) {
        b.writeln(t.result.trim().isEmpty ? '(no output)' : t.result.trim());
      } else if (t.error.isNotEmpty) {
        b.writeln(t.error);
      }
    }
    if (conflicts.isNotEmpty) {
      b.writeln();
      b.writeln('⚠ Files changed by more than one worker (the last write won — check they fit together):');
      for (final c in conflicts) {
        b.writeln('- $c');
      }
    }
    return b.toString().trim();
  }
}

/// Splits a job across workers: runs independent tasks side by side (up to the limits), waits for dependencies,
/// keeps two tasks from changing the same file at once, retries failures, times out stuck workers, collects
/// every result, and stops everything when asked.
class Orchestrator extends ChangeNotifier {
  Orchestrator({required this.runner, this.config = const OrchestratorConfig(), required this.mainTask, this.model = '', FileLocks? locks})
      : locks = locks ?? FileLocks();

  final WorkerRunner runner;
  final OrchestratorConfig config;
  final String mainTask;
  final String model;
  final FileLocks locks;

  final List<SubTask> tasks = <SubTask>[];
  final List<WorkerInfo> workers = <WorkerInfo>[];

  /// Notes about duplicates and the like, for the report and the trace.
  final List<String> notes = <String>[];

  /// Told about every start, finish and failure: (worker, text, failed).
  void Function(String worker, String text, bool failed)? onEvent;

  bool _cancelled = false;
  bool get cancelled => _cancelled;
  bool running = false;
  final Map<String, AbortHandle> _aborts = <String, AbortHandle>{};

  int get activeWorkers => workers.where((w) => w.state == WorkerState.active || w.state == WorkerState.waiting).length;

  /// How many workers may run at once for [taskCount] tasks.
  int concurrencyFor(int taskCount) {
    final byAgents = max(1, config.maxAgents - 1); // the main assistant is one agent
    final limit = max(1, min(config.maxWorkers, byAgents));
    switch (config.mode) {
      case 'sequential':
        return 1;
      case 'parallel':
        return limit;
      default:
        return max(1, min(limit, (taskCount / 2).ceil()));
    }
  }

  /// Checks the task list: no duplicates (merged), no unknown dependencies, no cycles.
  static List<SubTask> validate(List<SubTask> input, List<String> notes) {
    final out = <SubTask>[];
    final seenKeys = <String, SubTask>{};
    final ids = <String>{};
    for (final t in input) {
      final dup = seenKeys[t.key];
      if (dup != null) {
        notes.add('Skipped "${t.title}": the same task was already in the list.');
        continue;
      }
      if (!ids.add(t.id)) throw ArgumentError('Two tasks share the id "${t.id}".');
      seenKeys[t.key] = t;
      out.add(t);
    }
    for (final t in out) {
      for (final d in t.dependsOn) {
        if (!ids.contains(d)) throw ArgumentError('Task "${t.id}" depends on "$d", which is not in the list.');
        if (d == t.id) throw ArgumentError('Task "${t.id}" depends on itself.');
      }
    }
    // Cycle check (Kahn).
    final indeg = <String, int>{for (final t in out) t.id: t.dependsOn.where(ids.contains).length};
    final queue = <String>[for (final e in indeg.entries) if (e.value == 0) e.key];
    var seen = 0;
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      seen++;
      for (final t in out) {
        if (t.dependsOn.contains(id)) {
          indeg[t.id] = indeg[t.id]! - 1;
          if (indeg[t.id] == 0) queue.add(t.id);
        }
      }
    }
    if (seen != out.length) throw ArgumentError('The tasks depend on each other in a circle.');
    return out;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final a in _aborts.values) {
      a.abort();
    }
    notifyListeners();
  }

  void _emit(String worker, String text, {bool failed = false}) => onEvent?.call(worker, text, failed);

  /// Runs every task and returns when all are finished, failed or cancelled.
  Future<OrchestratorOutcome> run(List<SubTask> input) async {
    if (running) throw StateError('Already running');
    running = true;
    tasks
      ..clear()
      ..addAll(validate(input, notes));
    final slots = concurrencyFor(tasks.length);
    for (var i = 0; i < slots; i++) {
      workers.add(WorkerInfo('Worker ${i + 1}', model));
    }
    notifyListeners();

    final inFlight = <String, Future<void>>{};
    final slotOf = <String, WorkerInfo>{};

    bool depsDone(SubTask t) => t.dependsOn.every((d) => tasks.firstWhere((x) => x.id == d).state == TaskState.done);

    while (!_cancelled) {
      // A task whose dependency failed or was skipped can never run.
      for (final t in tasks.where((t) => t.state == TaskState.queued)) {
        final bad = t.dependsOn.where((d) {
          final s = tasks.firstWhere((x) => x.id == d).state;
          return s == TaskState.failed || s == TaskState.cancelled;
        });
        if (bad.isNotEmpty) {
          t.state = TaskState.cancelled;
          t.error = 'Not run: it needed "${bad.first}", which did not finish.';
          _emit('Orchestrator', 'Skipped "${t.title}" — a task it depends on failed', failed: true);
        }
      }
      final free = workers.where((w) => !slotOf.containsValue(w)).toList();
      final ready = tasks.where((t) => t.state == TaskState.queued && depsDone(t) && !locks.blocked(t.id, t.files)).toList()
        ..sort((a, b) {
          final p = b.priority.index.compareTo(a.priority.index);
          return p != 0 ? p : tasks.indexOf(a).compareTo(tasks.indexOf(b));
        });
      for (final t in ready) {
        if (free.isEmpty) break;
        // Two ready tasks that want the same file must not start together.
        if (locks.blocked(t.id, t.files)) continue;
        final w = free.removeAt(0);
        t.state = TaskState.running;
        t.worker = w.name;
        slotOf[t.id] = w;
        locks.claim(t.id, t.files);
        inFlight[t.id] = _execute(t, w).whenComplete(() {
          locks.release(t.id);
          slotOf.remove(t.id);
          inFlight.remove(t.id);
        });
      }
      notifyListeners();
      if (inFlight.isEmpty) break;
      await Future.any(inFlight.values);
    }

    if (_cancelled) {
      await Future.wait(inFlight.values.toList());
      for (final t in tasks) {
        if (t.state == TaskState.queued || t.state == TaskState.running) {
          t.state = TaskState.cancelled;
          if (t.error.isEmpty) t.error = 'Stopped before it finished.';
        }
      }
    } else {
      for (final t in tasks.where((t) => t.state == TaskState.queued)) {
        t.state = TaskState.cancelled;
        t.error = 'Not run: its files were never free or its dependencies never finished.';
      }
    }
    for (final w in workers) {
      if (w.state == WorkerState.active || w.state == WorkerState.waiting) w.finish(WorkerState.stopped);
    }
    running = false;
    notifyListeners();
    return OrchestratorOutcome(List<SubTask>.of(tasks), List<FileConflict>.of(locks.conflicts), _cancelled);
  }

  Future<void> _execute(SubTask t, WorkerInfo w) async {
    t.startedAt = DateTime.now();
    String lastError = '';
    for (var attempt = 0; attempt <= config.retries; attempt++) {
      if (_cancelled) break;
      t.attempts++;
      w.begin(t);
      _emit(w.name, 'Started "${t.title}"${attempt > 0 ? ' (attempt ${attempt + 1})' : ''}');
      final abort = AbortHandle();
      _aborts[t.id] = abort;
      final deps = <String, String>{
        for (final d in t.dependsOn) tasks.firstWhere((x) => x.id == d).title: tasks.firstWhere((x) => x.id == d).result,
      };
      final ctx = WorkerContext(worker: w, abort: abort, locks: locks, mainTask: mainTask, dependencyResults: deps);
      notifyListeners();
      try {
        // Stop wins over a worker that does not look at its abort handle.
        final out = await Future.any<String>(<Future<String>>[
          runner(t, ctx).timeout(config.timeout),
          abort.whenAborted.then<String>((_) => throw const _Stopped()),
        ]);
        if (_cancelled || abort.aborted) break;
        t.result = out;
        t.state = TaskState.done;
        t.endedAt = DateTime.now();
        w.finish(WorkerState.completed, result: out, note: 'Finished');
        _emit(w.name, 'Finished "${t.title}"');
        _aborts.remove(t.id);
        notifyListeners();
        return;
      } on TimeoutException {
        abort.abort();
        lastError = 'Timed out after ${config.timeout.inSeconds}s';
      } catch (e) {
        lastError = e.toString();
      } finally {
        _aborts.remove(t.id);
      }
      if (_cancelled) break;
      if (attempt < config.retries) {
        w.event('Failed ($lastError) — retrying');
        _emit(w.name, 'Retrying "${t.title}": $lastError', failed: true);
        await Future<void>.delayed(config.retryDelay);
      }
    }
    t.endedAt = DateTime.now();
    if (_cancelled) {
      t.state = TaskState.cancelled;
      t.error = 'Stopped before it finished.';
      w.finish(WorkerState.stopped, note: 'Stopped');
    } else {
      t.state = TaskState.failed;
      t.error = lastError;
      w.finish(WorkerState.failed, note: lastError);
      _emit(w.name, 'Failed "${t.title}": $lastError', failed: true);
    }
    notifyListeners();
  }
}
