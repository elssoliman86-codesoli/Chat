import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'orchestrator.dart';

/// The stages a task moves through. Each real event (a tool call, a model pass, a worker) is filed under the
/// stage it belongs to, so the timeline is a summary of what actually happened — not a script.
enum Stage { analyzing, understanding, planning, researching, files, delegating, executing, reviewing, testing, finalizing }

enum StageStatus { pending, running, completed, failed, waiting, cancelled }

enum TraceKind { status, model, tool, command, file, delegate, plan, warning, error }

enum TraceOutcome { running, completed, failed, cancelled }

extension StageInfo on Stage {
  String get title => switch (this) {
        Stage.analyzing => 'Analyzing Request',
        Stage.understanding => 'Understanding Requirements',
        Stage.planning => 'Planning',
        Stage.researching => 'Researching',
        Stage.files => 'Analyzing Files',
        Stage.delegating => 'Delegating Tasks',
        Stage.executing => 'Executing Commands',
        Stage.reviewing => 'Reviewing Results',
        Stage.testing => 'Testing',
        Stage.finalizing => 'Finalizing',
      };

  String get blurb => switch (this) {
        Stage.analyzing => 'Reading your message, attachments and the conversation',
        Stage.understanding => 'The model works out what is being asked',
        Stage.planning => 'Laying out the steps before starting',
        Stage.researching => 'Searching, browsing and reading sources',
        Stage.files => 'Reading and searching files and projects',
        Stage.delegating => 'Handing work to other models and workers',
        Stage.executing => 'Running commands and changing files',
        Stage.reviewing => 'The model reads what the tools returned',
        Stage.testing => 'Checking that the result works',
        Stage.finalizing => 'Writing the final answer',
      };
}

String stageStatusLabel(StageStatus s) => switch (s) {
      StageStatus.pending => 'Pending',
      StageStatus.running => 'Running',
      StageStatus.completed => 'Completed',
      StageStatus.failed => 'Failed',
      StageStatus.waiting => 'Waiting',
      StageStatus.cancelled => 'Cancelled',
    };

final RegExp _testCommand = RegExp(r'\b(pytest|unittest|jest|vitest|mocha|flutter test|npm (run )?test|yarn test|cargo test|go test|mvn test|gradle test|phpunit|rspec)\b|\btest\b', caseSensitive: false);

/// Which stage a tool call belongs to.
Stage stageForTool(String name, Map<String, dynamic> args) {
  switch (name) {
    case 'set_plan':
      return Stage.planning;
    case 'web_search':
    case 'image_search':
    case 'fetch_page':
    case 'browse_page':
    case 'browser_open':
    case 'browser_read':
    case 'browser_click':
    case 'browser_type':
    case 'browser_drag':
    case 'browser_scroll':
    case 'browser_back':
    case 'browser_devtools':
      return Stage.researching;
    case 'project_read':
    case 'project_list':
    case 'project_search':
    case 'termux_list_files':
      return Stage.files;
    case 'ask_advisor':
    case 'ask_web_chat':
    case 'run_parallel':
    case 'spawn_agent':
      return Stage.delegating;
    case 'project_check':
      return Stage.testing;
    case 'ask_user':
    case 'use_skill':
    case 'remember':
    case 'forget':
    case 'learn':
    case 'forget_lesson':
    case 'current_time':
      return Stage.understanding;
    case 'termux_run':
      return _testCommand.hasMatch((args['command'] ?? '').toString()) ? Stage.testing : Stage.executing;
    case 'python_run':
      return _testCommand.hasMatch((args['code'] ?? '').toString()) ? Stage.testing : Stage.executing;
  }
  if (name.startsWith('github_')) {
    const writes = {'github_comment', 'github_commit', 'github_create_issue', 'github_create_pr', 'github_create_repo', 'github_merge_pr'};
    return writes.contains(name) ? Stage.executing : Stage.researching;
  }
  return Stage.executing;
}

/// The terminal command a tool call runs, if it runs one.
String commandOf(String name, Map<String, dynamic> args) {
  if (name == 'termux_run') return (args['command'] ?? '').toString();
  if (name == 'python_run') {
    final code = (args['code'] ?? '').toString().trim();
    return code.isEmpty ? '' : 'python3 - <<EOF\n$code\nEOF';
  }
  return '';
}

/// Files a tool call changes: (path, what happened).
List<({String path, String op})> filesOf(String name, Map<String, dynamic> args) {
  final out = <({String path, String op})>[];
  String s(String k) => (args[k] ?? '').toString();
  switch (name) {
    case 'project_write':
      for (final f in (args['files'] as List?) ?? const <dynamic>[]) {
        if (f is Map && (f['path'] ?? '').toString().isNotEmpty) out.add((path: f['path'].toString(), op: 'written'));
      }
    case 'project_edit':
      if (s('path').isNotEmpty) out.add((path: s('path'), op: 'edited'));
    case 'project_delete':
      for (final p in (args['paths'] as List?) ?? const <dynamic>[]) {
        out.add((path: p.toString(), op: 'deleted'));
      }
    case 'project_move':
      if (s('from').isNotEmpty) out.add((path: '${s('from')} → ${s('to')}', op: 'moved'));
    case 'project_download':
      if (s('path').isNotEmpty) out.add((path: s('path'), op: 'downloaded'));
    case 'project_create':
      if (s('name').isNotEmpty) out.add((path: s('name'), op: 'created'));
  }
  return out;
}

class TraceEvent {
  TraceEvent({
    required this.id,
    required this.stage,
    required this.kind,
    required this.title,
    this.detail = '',
    this.tool = '',
    this.command = '',
    this.agent = '',
    List<({String path, String op})>? files,
    this.running = false,
    DateTime? at,
  })  : files = files ?? <({String path, String op})>[],
        at = at ?? DateTime.now();

  final String id;

  /// Can move: a model pass that turns out to be the last one is re-filed under Finalizing.
  Stage stage;
  final TraceKind kind;
  String title;
  String detail;
  final String tool;
  final String command;

  /// The worker or agent that produced it ('' = the main assistant).
  final String agent;
  final List<({String path, String op})> files;
  final DateTime at;
  DateTime? endedAt;
  bool running;
  bool failed = false;

  /// What the tool returned (shortened).
  String output = '';

  /// The reasoning text the provider streamed during this model pass (only providers that send it have any).
  final StringBuffer _reasoning = StringBuffer();
  bool reasoningCut = false;

  /// True while this is a live preview of a tool call still being written (not a finished call).
  bool preview = false;

  String get reasoning => _reasoning.toString();
  int get reasoningLength => _reasoning.length;

  static const int reasoningLimit = 80000;

  void addReasoning(String text) {
    if (reasoningCut) return;
    if (_reasoning.length + text.length > reasoningLimit) {
      _reasoning.write(text.substring(0, reasoningLimit - _reasoning.length));
      reasoningCut = true;
      return;
    }
    _reasoning.write(text);
  }

  Duration? get took => endedAt?.difference(at);
}

/// What a tool call that is still being written says so far: a title (for a file, its name) and the text being
/// written, decoded from the half-finished JSON the model has sent until now.
({String title, String body, int files}) describeToolArgs(String tool, String partialJson) {
  String unescape(String s) {
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch != '\\' || i + 1 >= s.length) {
        if (ch != '\\') b.write(ch);
        continue;
      }
      final n = s[++i];
      switch (n) {
        case 'n':
          b.write('\n');
        case 't':
          b.write('\t');
        case 'r':
          break;
        case 'u':
          if (i + 4 < s.length) {
            final code = int.tryParse(s.substring(i + 1, i + 5), radix: 16);
            if (code != null) {
              b.writeCharCode(code);
              i += 4;
            }
          }
        default:
          b.write(n);
      }
    }
    return b.toString();
  }

  final pathRe = RegExp(r'"(?:path|file|filename)"\s*:\s*"((?:[^"\\]|\\.)*)"');
  final paths = pathRe.allMatches(partialJson).toList();
  final bodyRe = RegExp(r'"(?:content|command|code|text|new_str|prompt|script)"\s*:\s*"((?:[^"\\]|\\.)*)');
  final from = paths.isEmpty ? 0 : paths.last.end;
  final bodies = bodyRe.allMatches(partialJson.substring(from)).toList();
  final body = bodies.isEmpty ? '' : unescape(bodies.last.group(1) ?? '');
  final path = paths.isEmpty ? '' : unescape(paths.last.group(1) ?? '');
  final isFile = tool.startsWith('project_') || tool == 'write_file';
  final title = path.isNotEmpty
      ? (isFile ? 'Writing $path' : '$tool — $path')
      : 'Writing the $tool call';
  return (title: title, body: body, files: paths.length);
}

/// The record of one turn: every model pass, tool call, command, file change and worker, in order, as they
/// really happened. The Thinking panel is drawn from this.
class ExecutionTrace extends ChangeNotifier {
  ExecutionTrace({required this.conversationId, required this.request, this.attachments = 0, this.model = ''}) : startedAt = DateTime.now();

  final String conversationId;
  final String request;
  final int attachments;
  String model;
  final DateTime startedAt;
  DateTime? endedAt;
  TraceOutcome outcome = TraceOutcome.running;
  String error = '';

  final List<TraceEvent> events = <TraceEvent>[];

  /// Set while the assistant is waiting for the person (a question, an approval, the browser).
  bool waiting = false;

  /// The workers of this task, when it split work across them (drawn by the Multi-Agent Monitor).
  Orchestrator? orchestrator;

  int activeAgents = 0;
  int activeWorkers = 0;
  int agentsSeen = 0;

  /// Tokens of finished model passes; the current pass is added from the live stream numbers.
  int tokens = 0;
  Duration generating = Duration.zero;
  int passes = 0;

  int _seq = 0;
  TraceEvent? _pass;

  bool get running => outcome == TraceOutcome.running;
  Duration get elapsed => (endedAt ?? DateTime.now()).difference(startedAt);

  TraceEvent log(
    Stage stage,
    TraceKind kind,
    String title, {
    String detail = '',
    String tool = '',
    String command = '',
    String agent = '',
    List<({String path, String op})>? files,
    bool running = false,
    bool failed = false,
    String output = '',
  }) {
    final e = TraceEvent(
      id: 'e${_seq++}',
      stage: stage,
      kind: kind,
      title: title,
      detail: detail,
      tool: tool,
      command: command,
      agent: agent,
      files: files,
      running: running,
    )
      ..failed = failed
      ..output = output;
    if (!running) e.endedAt = e.at;
    events.add(e);
    notifyListeners();
    return e;
  }

  void finishEvent(TraceEvent e, {String? output, bool failed = false, String? detail, String? title}) {
    e.running = false;
    e.endedAt = DateTime.now();
    e.failed = failed;
    if (output != null) e.output = output.length > 4000 ? '${output.substring(0, 4000)}…' : output;
    if (detail != null) e.detail = detail;
    if (title != null) e.title = title;
    notifyListeners();
  }

  DateTime _lastPing = DateTime.fromMillisecondsSinceEpoch(0);

  void _ping({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastPing).inMilliseconds < 120) return;
    _lastPing = now;
    notifyListeners();
  }

  /// Characters of reasoning the providers reported without sending the text.
  int hiddenReasoning = 0;

  /// Reasoning text from the provider during the current model pass. [chars] is how much the provider says it
  /// produced; [text] is empty when the provider does not send it.
  void addReasoning(String text, {int chars = 0}) {
    final p = _pass;
    if (p == null) return;
    if (text.isEmpty) {
      hiddenReasoning += chars;
      _ping();
      return;
    }
    p.addReasoning(text);
    _ping();
  }

  final Map<int, TraceEvent> _previews = <int, TraceEvent>{};
  final Map<int, StringBuffer> _previewArgs = <int, StringBuffer>{};

  /// A tool call is being written: show what it says so far (a file's name and the text so far).
  void previewTool(int index, String tool, String chunk) {
    final buf = _previewArgs.putIfAbsent(index, StringBuffer.new)..write(chunk);
    final d = describeToolArgs(tool, buf.toString());
    var e = _previews[index];
    if (e == null) {
      e = log(
        stageForTool(tool, const <String, dynamic>{}),
        TraceKind.file,
        d.title,
        tool: tool,
        running: true,
      )..preview = true;
      _previews[index] = e;
    }
    e.title = d.files > 1 ? '${d.title} (file ${d.files})' : d.title;
    final body = d.body;
    e.output = body.length > 6000 ? '…${body.substring(body.length - 6000)}' : body;
    e.detail = '${buf.length} characters so far';
    _ping();
  }

  /// The model finished writing its calls: the live previews give way to the real tool events that follow.
  void clearPreviews() {
    if (_previews.isEmpty) return;
    events.removeWhere((e) => e.preview);
    _previews.clear();
    _previewArgs.clear();
    notifyListeners();
  }

  void setWaiting(bool v) {
    if (waiting == v) return;
    waiting = v;
    notifyListeners();
  }

  void setWorkers({int? agents, int? workers}) {
    if (agents != null) {
      activeAgents = agents;
      if (agents > agentsSeen) agentsSeen = agents;
    }
    if (workers != null) activeWorkers = workers;
    notifyListeners();
  }

  // ── model passes ──

  /// A request goes to the model. The first one is the model working out the task; later ones are the model
  /// reading tool results.
  TraceEvent passStart(String model) {
    clearPreviews();
    this.model = model;
    final first = passes == 0;
    passes++;
    _pass = log(
      first ? Stage.understanding : Stage.reviewing,
      TraceKind.model,
      first ? 'Sent the request to $model' : 'Sent the tool results back to $model',
      detail: 'Connecting…',
      running: true,
    );
    return _pass!;
  }

  void passFirstToken(Duration latency) {
    final p = _pass;
    if (p == null) return;
    p.detail = 'First token after ${(latency.inMilliseconds / 1000).toStringAsFixed(1)} s';
    notifyListeners();
  }

  void passReconnecting(int attempt) {
    final p = _pass;
    if (p == null) return;
    p.detail = 'Connection dropped — reconnecting ($attempt)';
    notifyListeners();
  }

  /// The model pass ended. A pass that asked for no tools is the final answer.
  void passEnd({required bool hadTools, int outputTokens = 0, Duration took = Duration.zero, String summary = '', bool failed = false}) {
    final p = _pass;
    _pass = null;
    tokens += outputTokens;
    generating += took;
    if (p == null) return;
    if (!hadTools && !failed) {
      p.stage = Stage.finalizing;
      p.title = 'Wrote the answer';
    }
    finishEvent(p, failed: failed, detail: summary.isEmpty ? p.detail : summary);
  }

  // ── tools ──

  TraceEvent toolStart(ToolCall call, {required String title, String detail = '', String agent = ''}) {
    final command = commandOf(call.name, call.args);
    final files = filesOf(call.name, call.args);
    final kind = call.name == 'set_plan'
        ? TraceKind.plan
        : (command.isNotEmpty ? TraceKind.command : (files.isNotEmpty ? TraceKind.file : (call.name == 'ask_advisor' || call.name == 'ask_web_chat' || call.name == 'run_parallel' ? TraceKind.delegate : TraceKind.tool)));
    if (call.name == 'ask_user') waiting = true;
    return log(
      stageForTool(call.name, call.args),
      kind,
      title,
      detail: detail,
      tool: call.name,
      command: command,
      files: files,
      agent: agent,
      running: true,
    );
  }

  void toolEnd(TraceEvent e, {required String result, required bool failed}) {
    if (e.tool == 'ask_user') waiting = false;
    finishEvent(e, output: result, failed: failed);
  }

  void end(TraceOutcome o, {String error = ''}) {
    if (!running) return;
    outcome = o;
    this.error = error;
    endedAt = DateTime.now();
    waiting = false;
    activeAgents = 0;
    activeWorkers = 0;
    _previews.clear();
    _previewArgs.clear();
    events.removeWhere((e) => e.preview);
    final p = _pass;
    if (p != null) finishEvent(p, failed: o == TraceOutcome.failed);
    _pass = null;
    for (final e in events) {
      if (e.running) {
        e.running = false;
        e.endedAt = endedAt;
        if (o == TraceOutcome.cancelled) e.detail = e.detail.isEmpty ? 'Stopped' : '${e.detail} (stopped)';
      }
    }
    notifyListeners();
  }

  // ── what the panel shows ──

  List<TraceEvent> eventsOf(Stage s) => events.where((e) => e.stage == s).toList();

  /// The stage the latest event belongs to.
  Stage? get current => events.isEmpty ? null : events.last.stage;

  StageStatus statusOf(Stage s) {
    final list = eventsOf(s);
    if (list.isEmpty) {
      if (s == Stage.analyzing) return running ? StageStatus.running : StageStatus.completed;
      return running ? StageStatus.pending : StageStatus.cancelled;
    }
    final live = list.any((e) => e.running);
    if (running) {
      if (waiting && (list.any((e) => e.tool == 'ask_user' && e.running))) return StageStatus.waiting;
      if (live) return StageStatus.running;
      if (current == s) return list.last.failed ? StageStatus.failed : StageStatus.running;
      return list.last.failed && list.every((e) => e.failed || e.kind == TraceKind.status) ? StageStatus.failed : _doneOrFailed(list);
    }
    if (outcome == TraceOutcome.cancelled && current == s) return StageStatus.cancelled;
    return _doneOrFailed(list);
  }

  StageStatus _doneOrFailed(List<TraceEvent> list) {
    final tools = list.where((e) => e.kind != TraceKind.status && e.kind != TraceKind.warning).toList();
    if (tools.isNotEmpty && tools.last.failed) return StageStatus.failed;
    return StageStatus.completed;
  }

  /// The stages to draw: all of them while the task runs (the ones ahead are "pending"), only those that
  /// actually happened once it is over.
  List<Stage> get visibleStages {
    if (running) return Stage.values;
    return Stage.values.where((s) => s == Stage.analyzing || eventsOf(s).isNotEmpty).toList();
  }

  DateTime? stageStart(Stage s) {
    final l = eventsOf(s);
    return l.isEmpty ? (s == Stage.analyzing ? startedAt : null) : l.first.at;
  }

  Duration? stageDuration(Stage s) {
    final l = eventsOf(s);
    if (l.isEmpty) {
      if (s == Stage.analyzing) {
        final first = events.isEmpty ? null : events.first.at;
        return first == null ? (running ? elapsed : Duration.zero) : first.difference(startedAt);
      }
      return null;
    }
    final end = l.any((e) => e.running) || (running && current == s) ? DateTime.now() : l.map((e) => e.endedAt ?? e.at).reduce((a, b) => a.isAfter(b) ? a : b);
    return end.difference(l.first.at);
  }

  /// One factual line about a stage, built from its events.
  String summaryOf(Stage s) {
    final l = eventsOf(s);
    if (l.isEmpty) {
      if (s == Stage.analyzing) {
        return 'Read your message (${request.length} characters)${attachments > 0 ? ' and $attachments attachment${attachments == 1 ? '' : 's'}' : ''}.';
      }
      return s.blurb;
    }
    final tools = <String, int>{};
    var failed = 0;
    var running = 0;
    for (final e in l) {
      if (e.tool.isNotEmpty) tools[e.tool] = (tools[e.tool] ?? 0) + 1;
      if (e.failed) failed++;
      if (e.running) running++;
    }
    final parts = <String>[];
    if (tools.isNotEmpty) {
      final n = tools.values.fold<int>(0, (a, b) => a + b);
      parts.add('$n tool call${n == 1 ? '' : 's'} (${tools.entries.map((e) => e.value > 1 ? '${e.key} ×${e.value}' : e.key).join(', ')})');
    }
    final passes = l.where((e) => e.kind == TraceKind.model).length;
    if (passes > 0) parts.add('$passes model pass${passes == 1 ? '' : 'es'}');
    final files = l.fold<int>(0, (a, e) => a + e.files.length);
    if (files > 0) parts.add('$files file${files == 1 ? '' : 's'} changed');
    if (failed > 0) parts.add('$failed failed');
    if (running > 0) parts.add('$running in progress');
    return parts.isEmpty ? s.blurb : '${parts.join(', ')}.';
  }

  /// Tools used with how many times and how many failed.
  Map<String, ({int count, int failed})> get toolsUsed {
    final m = <String, ({int count, int failed})>{};
    for (final e in events) {
      if (e.tool.isEmpty) continue;
      final cur = m[e.tool] ?? (count: 0, failed: 0);
      m[e.tool] = (count: cur.count + 1, failed: cur.failed + (e.failed ? 1 : 0));
    }
    return m;
  }

  List<TraceEvent> get commands => events.where((e) => e.command.isNotEmpty).toList();

  /// Every file change, latest state per path.
  List<({String path, String op, bool failed})> get modifiedFiles {
    final m = <String, ({String path, String op, bool failed})>{};
    for (final e in events) {
      for (final f in e.files) {
        m[f.path] = (path: f.path, op: f.op, failed: e.failed);
      }
    }
    return m.values.toList();
  }

  List<TraceEvent> get problems => events.where((e) => e.failed || e.kind == TraceKind.error || e.kind == TraceKind.warning).toList();

  /// Units of work that have finished / are in progress, for the overview bar.
  int get stepsTotal => events.where((e) => e.kind != TraceKind.status).length;
  int get stepsCompleted => events.where((e) => e.kind != TraceKind.status && !e.running && !e.failed).length;
  int get stepsRunning => events.where((e) => e.running).length;

  String get statusText {
    switch (outcome) {
      case TraceOutcome.completed:
        return 'Completed';
      case TraceOutcome.failed:
        return 'Failed';
      case TraceOutcome.cancelled:
        return 'Stopped';
      case TraceOutcome.running:
        if (waiting) return 'Waiting for you';
        for (final e in events.reversed) {
          if (e.preview) return e.title;
        }
        final pass = _pass;
        if (pass != null && pass.reasoningLength > 0 && pass.running) return 'Reasoning…';
        final c = current;
        return c == null ? 'Starting' : c.title;
    }
  }
}

/// The latest trace of each conversation, so the Thinking panel can show the running task or the last one.
class TraceHub extends ChangeNotifier {
  final Map<String, ExecutionTrace> _byConversation = <String, ExecutionTrace>{};

  ExecutionTrace? of(String conversationId) => _byConversation[conversationId];

  void put(ExecutionTrace t) {
    _byConversation.remove(t.conversationId);
    _byConversation[t.conversationId] = t;
    // Old traces are dropped so they cannot pile up in memory.
    while (_byConversation.length > 30) {
      final oldest = _byConversation.keys.first;
      _byConversation.remove(oldest);
    }
    notifyListeners();
  }
}
