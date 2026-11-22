
import 'orchestrator.dart';
import 'windows_scan.dart';

/// What came back from one command run in Termux.
class ShellOutput {
  const ShellOutput({this.stdout = '', this.stderr = '', this.exitCode = 0, this.error = ''});

  final String stdout;
  final String stderr;
  final int exitCode;

  /// Set when the command could not run at all (Termux missing, no permission, timed out).
  final String error;

  /// stdout with the PowerShell noise removed, and stderr appended when it says something useful.
  String get text {
    final out = cleanPowerShellOutput(stdout);
    if (out.isNotEmpty) return out;
    return cleanPowerShellOutput(stderr);
  }

  /// ssh itself failed (exit 255) rather than the command on the PC.
  bool get sshFailed => exitCode == 255;
}

typedef ShellRunner = Future<ShellOutput> Function(String command, int timeoutSec);

/// The scan could not start or had to stop; [message] says why in plain words.
class ScanFailure implements Exception {
  const ScanFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class ScanStopped implements Exception {
  const ScanStopped();
}

class WindowsScanOutcome {
  WindowsScanOutcome({required this.target, required this.machine, required this.psVersion, required this.results, required this.seconds, required this.workers, required this.stopped});

  final SshTarget target;
  final String machine;
  final String psVersion;
  final List<ScanResult> results;
  final int seconds;
  final int workers;
  final bool stopped;

  int get failed => results.where((r) => !r.ok).length;
  int get ok => results.where((r) => r.ok).length;
}

/// Runs the whole scan: finds the SSH connection, checks it reaches a Windows PC, then runs every check with
/// [workers] at a time and returns the outputs. It only reads; the person is asked before anything changes.
class WindowsScanRunner {
  WindowsScanRunner({
    required this.shell,
    required this.workers,
    this.saved = const <SshTarget>[],
    this.remembered,
    this.askTarget,
    this.onStatus,
    this.onOrchestrator,
    this.retryDelay = const Duration(seconds: 3),
    List<ScanCheck>? checks,
  }) : checks = checks ?? kScanChecks;

  final ShellRunner shell;
  final int workers;

  /// Hosts the person saved in the app.
  final List<SshTarget> saved;

  /// The target that worked last time.
  final SshTarget? remembered;

  /// Asked for `user@host` when nothing was found or nothing worked. Returns null to give up.
  final Future<String?> Function(String why)? askTarget;

  /// Progress lines for the Thinking panel: (text, failed).
  final void Function(String text, {bool failed})? onStatus;

  /// Called as soon as the workers exist so the monitor can draw them.
  final void Function(Orchestrator o)? onOrchestrator;
  final Duration retryDelay;
  final List<ScanCheck> checks;

  Orchestrator? _orch;
  bool _stopped = false;

  void stop() {
    _stopped = true;
    _orch?.cancel();
  }

  void _say(String text, {bool failed = false}) => onStatus?.call(text, failed: failed);

  void _checkStopped() {
    if (_stopped) throw const ScanStopped();
  }

  /// The target that answers as a Windows PC, with its name and PowerShell version.
  Future<(SshTarget, String, String)> connect() async {
    _say('Looking for your SSH connection in Termux…');
    final found = await shell(kDiscoveryCommand, 40);
    _checkStopped();
    if (found.error.isNotEmpty) throw ScanFailure('Termux could not run commands: ${found.error}');
    if (sshMissing(found.stdout)) {
      throw const ScanFailure('The ssh program is not installed in Termux. Open Termux and run: pkg install openssh — then connect to the PC and try again.');
    }
    final candidates = <SshTarget>[
      if (remembered != null) remembered!,
      ...saved,
      ...parseDiscovery(found.stdout),
    ];
    final seen = <String>{};
    final unique = <SshTarget>[for (final t in candidates) if (seen.add(t.key)) t].take(8).toList();
    _say(unique.isEmpty ? 'No SSH connection found yet' : 'Found ${unique.length} possible connection${unique.length == 1 ? '' : 's'}: ${unique.map((t) => t.label).join(', ')}');

    final tried = <String>[];
    var pool = unique;
    for (var round = 0; round < 2; round++) {
      if (pool.isNotEmpty) {
        final probes = await Future.wait(pool.map((t) async {
          final r = await shell(remoteCommand(t, kProbeScript), 30);
          return (t, r);
        }));
        _checkStopped();
        for (final (t, r) in probes) {
          final p = parseProbe(r.text);
          if (p != null) {
            _say('Connected to ${p.name} (${t.label}, PowerShell ${p.ps})');
            return (t, p.name, p.ps);
          }
          final why = explainSshFailure('${r.stderr}\n${r.stdout}\n${r.error}');
          tried.add('${t.label}${t.source.isEmpty ? '' : ' (${t.source})'}: ${why.isEmpty ? (r.text.isEmpty ? 'no answer' : 'it did not answer like a Windows PC') : why}');
          _say('${t.label} did not work${why.isEmpty ? '' : ': $why'}', failed: true);
        }
      }
      if (round == 1) break;
      final ask = askTarget;
      if (ask == null) break;
      final answer = await ask(pool.isEmpty
          ? 'I could not find an SSH connection to your Windows PC in Termux. Type it as user@host (add :port if it is not 22), for example Ahmed@192.168.1.20'
          : 'None of the SSH connections I found reached a Windows PC:\n${tried.join('\n')}\n\nType the right one as user@host (add :port if it is not 22).');
      _checkStopped();
      final t = _parseTyped(answer);
      if (t == null) break;
      pool = <SshTarget>[t];
    }
    throw ScanFailure(
      '${tried.isEmpty ? 'No SSH connection to a Windows PC was found.' : 'Could not reach a Windows PC over SSH.'}'
      '${tried.isEmpty ? '' : '\n${tried.map((e) => '• $e').join('\n')}'}'
      '\nConnect from Termux with a key (ssh-keygen, then add the public key to the PC) so it works without typing a password, then try again.',
    );
  }

  static SshTarget? _parseTyped(String? answer) {
    final a = (answer ?? '').trim();
    if (a.isEmpty) return null;
    final m = RegExp(r'^(?:ssh\s+)?(\S+?)(?::(\d{1,5}))?$').firstMatch(a);
    if (m == null) return parseSshCommandLine(a.startsWith('ssh ') ? a : 'ssh $a', source: 'typed by you');
    if (a.startsWith('ssh ')) return parseSshCommandLine(a, source: 'typed by you');
    return SshTarget(destination: m.group(1)!, port: int.tryParse(m.group(2) ?? '') ?? 22, source: 'typed by you');
  }

  Future<WindowsScanOutcome> run() async {
    final clock = Stopwatch()..start();
    final (target, machine, ps) = await connect();
    _checkStopped();

    final ordered = <ScanCheck>[...checks.where((c) => c.slow), ...checks.where((c) => !c.slow)];
    final tasks = <SubTask>[
      for (final c in ordered) SubTask(id: c.id, title: c.title, prompt: c.id, priority: c.slow ? TaskPriority.high : TaskPriority.normal),
    ];
    final orch = Orchestrator(
      mainTask: 'Full Windows scan of $machine',
      model: 'scan',
      config: OrchestratorConfig(
        maxWorkers: workers,
        maxAgents: workers + 1,
        mode: 'parallel',
        timeout: const Duration(seconds: 330),
        retries: 1,
        retryDelay: retryDelay,
      ),
      runner: (task, ctx) async {
        final c = scanCheckById(task.id) ?? checks.firstWhere((x) => x.id == task.id);
        ctx.event('Running on $machine');
        final started = DateTime.now();
        final r = await shell(remoteCommand(target, c.script), c.timeoutSec);
        if (ctx.abort.aborted) throw const ScanStopped();
        if (r.error.isNotEmpty) throw ScanFailure(r.error);
        final text = cleanPowerShellOutput(r.stdout);
        // ssh itself failed, or the command failed without printing anything: that is a failure to retry, not "nothing found".
        if (r.sshFailed || (r.exitCode != 0 && text.isEmpty)) {
          final err = cleanPowerShellOutput(r.stderr);
          final why = explainSshFailure('$err\n${r.stdout}');
          throw ScanFailure('${r.sshFailed ? 'The connection failed' : 'The check failed (exit code ${r.exitCode})'}'
              '${why.isEmpty ? (err.isEmpty ? '' : ': ${err.split('\n').first}') : ': $why'}');
        }
        ctx.event('Done in ${DateTime.now().difference(started).inSeconds}s');
        return text;
      },
    );
    _orch = orch;
    onOrchestrator?.call(orch);
    orch.onEvent = (worker, text, failed) => _say('$worker: $text', failed: failed);
    _say('Running ${tasks.length} checks with $workers parallel workers…');
    final outcome = await orch.run(tasks);
    clock.stop();
    final results = <ScanResult>[];
    for (final c in checks) {
      final t = outcome.tasks.where((x) => x.id == c.id).firstOrNull;
      if (t == null) continue;
      final secs = t.startedAt == null || t.endedAt == null ? 0 : t.endedAt!.difference(t.startedAt!).inSeconds;
      results.add(ScanResult(
        c,
        output: t.state == TaskState.done ? t.result : '',
        error: t.state == TaskState.done ? '' : (t.error.isEmpty ? 'did not run' : t.error),
        seconds: secs,
        attempts: t.attempts,
      ));
    }
    return WindowsScanOutcome(
      target: target,
      machine: machine,
      psVersion: ps,
      results: results,
      seconds: clock.elapsed.inSeconds,
      workers: workers,
      stopped: outcome.cancelled,
    );
  }
}
