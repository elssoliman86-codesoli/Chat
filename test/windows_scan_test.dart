import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/agents/windows_scan.dart';
import 'package:omni_chat/agents/windows_scan_runner.dart';

const String _discovery = '''
@@SSH_BIN
/data/data/com.termux/files/usr/bin/ssh
@@PROCS
ssh -p 2222 -i /data/x/key Ahmed@192.168.1.20
@@CONFIG
Host office
  HostName 10.0.0.5
  User admin
Host *
  ServerAliveInterval 30
@@HISTORY
ssh Sara@pc-sara
ssh -l bob 10.9.9.9
@@KNOWN
[192.168.1.50]:2200 ssh-ed25519 AAAA
|1|hashed|value
@@KEYS
id_ed25519
@@END
''';

String _scriptOf(String command) {
  final all = decodedScripts(command);
  return all.isEmpty ? '' : all.first.replaceFirst(kPsPrelude, '');
}

void main() {
  group('encoding', () {
    test('a script survives the round trip, including non-Latin text', () {
      const text = r'Write-Output "مرحبا $env:COMPUTERNAME"';
      expect(psDecode(psEncode(text)).replaceFirst(kPsPrelude, ''), text);
    });

    test('every check fits in one command line', () {
      const t = SshTarget(destination: 'user@host');
      for (final c in kScanChecks) {
        final cmd = remoteCommand(t, c.script);
        expect(cmd.length, lessThan(7600), reason: '${c.id} is too long (${cmd.length})');
        expect(cmd, contains('-EncodedCommand'));
      }
    });

    test('check ids are unique and every area is covered', () {
      final ids = kScanChecks.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(kScanChecks.map((c) => c.category).toSet(), ScanCategory.values.toSet());
      expect(kScanChecks.where((c) => c.category == ScanCategory.ram).length, greaterThanOrEqualTo(5));
      expect(kScanChecks.length, greaterThanOrEqualTo(25));
    });

    test('the scripts are balanced', () {
      for (final c in kScanChecks) {
        final s = c.script;
        expect('{'.allMatches(s).length, '}'.allMatches(s).length, reason: '${c.id} braces');
        expect('('.allMatches(s).length, ')'.allMatches(s).length, reason: '${c.id} parentheses');
        expect('['.allMatches(s).length, ']'.allMatches(s).length, reason: '${c.id} brackets');
        expect("'".allMatches(s).length % 2, 0, reason: '${c.id} single quotes');
        expect('"'.allMatches(s).length % 2, 0, reason: '${c.id} double quotes');
      }
    });
  });

  group('read-only guarantee', () {
    test('no check of the scan changes anything', () {
      const t = SshTarget(destination: 'user@host');
      for (final c in kScanChecks) {
        expect(isRemoteChange(remoteCommand(t, c.script)), isFalse, reason: '${c.id} looks like it changes the PC');
      }
      expect(isRemoteChange(remoteCommand(t, kProbeScript)), isFalse);
    });

    test('a command that changes the PC is caught, plain or encoded', () {
      expect(isRemoteChange("ssh me@pc powershell -Command 'Remove-Item C:\\\\x\\\\bad.exe'"), isTrue);
      expect(isRemoteChange("ssh me@pc 'taskkill /F /IM bad.exe'"), isTrue);
      expect(isRemoteChange('ssh me@pc "schtasks /delete /tn Evil /f"'), isTrue);
      expect(isRemoteChange('ssh me@pc "reg delete HKCU\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run /v Bad /f"'), isTrue);
      const t = SshTarget(destination: 'me@pc');
      expect(isRemoteChange(remoteCommand(t, 'Stop-Process -Id 123 -Force')), isTrue);
      expect(isRemoteChange(remoteCommand(t, r'Get-Process; Disable-ScheduledTask -TaskName Evil')), isTrue);
      expect(isRemoteChange(remoteCommand(t, r'Move-Item C:\Users\x\bad.exe C:\Quarantine')), isTrue);
    });

    test('reading over ssh, and local commands, are not held back', () {
      const t = SshTarget(destination: 'me@pc');
      expect(isRemoteChange(remoteCommand(t, 'Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5')), isFalse);
      expect(isRemoteChange("ssh me@pc powershell -Command 'Get-Service'"), isFalse);
      expect(isRemoteChange('rm -rf ~/old'), isFalse);
      expect(isRemoteChange('ls -la'), isFalse);
    });

    test('the text shown for approval is the decoded script', () {
      const t = SshTarget(destination: 'me@pc');
      final d = describeRemoteChange(remoteCommand(t, 'Remove-Item C:\\bad.exe'));
      expect(d, contains('Remove-Item'));
      expect(d, isNot(contains('EncodedCommand')));
    });
  });

  group('finding the connection', () {
    test('a command line gives its destination, port and key', () {
      final t = parseSshCommandLine('ssh -p 2222 -i /k/key Ahmed@192.168.1.20')!;
      expect(t.destination, 'Ahmed@192.168.1.20');
      expect(t.port, 2222);
      expect(t.identity, '/k/key');
      expect(parseSshCommandLine('ssh -l bob 10.9.9.9')!.destination, 'bob@10.9.9.9');
      expect(parseSshCommandLine('ssh -o StrictHostKeyChecking=no me@h')!.destination, 'me@h');
      expect(parseSshCommandLine('echo hello'), isNull);
      expect(parseSshCommandLine('ssh -V'), isNull);
    });

    test('discovery lists running sessions first, then config, history and known hosts', () {
      final found = parseDiscovery(_discovery);
      expect(found.first.destination, 'Ahmed@192.168.1.20');
      expect(found.first.port, 2222);
      final names = found.map((t) => t.destination).toList();
      expect(names, containsAll(<String>['office', 'Sara@pc-sara', 'bob@10.9.9.9', '192.168.1.50']));
      expect(names, isNot(contains('*')));
      expect(found.where((t) => t.destination == '192.168.1.50').single.port, 2200);
      expect(names.toSet().length, names.length);
    });

    test('a missing ssh program is noticed', () {
      expect(sshMissing('@@SSH_BIN\nmissing\n@@PROCS\n'), isTrue);
      expect(sshMissing(_discovery), isFalse);
    });

    test('the probe answer is read, and anything else is rejected', () {
      expect(parseProbe('OMNI_WIN DESKTOP-1 PS5.1.19041.1')!.name, 'DESKTOP-1');
      expect(parseProbe('OMNI_WIN DESKTOP-1 PS5.1.19041.1')!.ps, '5.1.19041.1');
      expect(parseProbe('bash: powershell: command not found'), isNull);
    });

    test('ssh errors are explained in plain words', () {
      expect(explainSshFailure('user@h: Permission denied (publickey,password).'), contains('refused the login'));
      expect(explainSshFailure('ssh: connect to host h port 22: Connection refused'), contains('OpenSSH'));
      expect(explainSshFailure('Connection timed out'), contains('did not answer'));
      expect(explainSshFailure('something else'), '');
    });

    test('the ssh command uses a shared connection and never prompts', () {
      const t = SshTarget(destination: 'me@pc', port: 2222, identity: '~/.ssh/pc');
      expect(t.prefix, contains('BatchMode=yes'));
      expect(t.prefix, contains('ControlMaster=auto'));
      expect(t.prefix, contains('-p 2222'));
      expect(t.prefix, contains("-i ~/'.ssh/pc'"));
      expect(t.prefix, endsWith("'me@pc'"));
      const p = SshTarget(destination: 'me@pc', password: "p'w");
      expect(p.prefix, startsWith('sshpass -p'));
      expect(p.prefix, contains('BatchMode=no'));
    });

    test('the remembered target round-trips', () {
      const t = SshTarget(destination: 'me@pc', port: 2200, identity: '/k');
      final back = SshTarget.fromSetting(t.toSetting())!;
      expect(back.destination, 'me@pc');
      expect(back.port, 2200);
      expect(back.identity, '/k');
      expect(SshTarget.fromSetting(''), isNull);
    });
  });

  group('output', () {
    test('PowerShell progress noise and ssh warnings are removed', () {
      expect(cleanPowerShellOutput('line1\r\nline2\r\n#< CLIXML\n<Objs>junk</Objs>'), 'line1\nline2');
      expect(cleanPowerShellOutput('Warning: Permanently added \'h\' (ED25519) to the list of known hosts.\nreal'), 'real');
    });

    test('markers are counted', () {
      final r = <ScanResult>[
        ScanResult(kScanChecks.firstWhere((c) => c.id == 'masquerade'), output: 'WRONG PATH: 1 svchost.exe -> C:\\x\nWRONG PATH: 2 lsass.exe -> C:\\y'),
        ScanResult(kScanChecks.firstWhere((c) => c.id == 'software'), output: 'FOUND: AnyDesk 7'),
      ];
      final t = triage(r);
      expect(t, contains('wrong folder: 2'));
      expect(t, contains('Remote-access'));
      expect(triage(<ScanResult>[ScanResult(kScanChecks.first, output: 'fine')]), contains('no specific markers'));
    });

    test('evidence stays within its budget and keeps every check', () {
      final big = List<String>.filled(4000, 'x' * 50).join('\n');
      final results = <ScanResult>[for (final c in kScanChecks) ScanResult(c, output: big, seconds: 3)];
      final e = buildEvidence(results, budget: 60000);
      expect(e.length, lessThan(60000 + kScanChecks.length * 400));
      for (final c in kScanChecks) {
        expect(e, contains('[${c.id}]'));
      }
    });

    test('a failed check is shown as failed, not as empty', () {
      final e = buildEvidence(<ScanResult>[ScanResult(kScanChecks.first, error: 'timed out')]);
      expect(e, contains('FAILED'));
      expect(e, contains('timed out'));
    });

    test('the report request demands approval before any change', () {
      final text = buildReportRequest(
        evidence: 'E',
        triageText: 'T',
        target: const SshTarget(destination: 'me@pc'),
        machine: 'PC1',
        workers: 10,
        seconds: 95,
        failed: 0,
      );
      expect(text, contains('Proposed cleanup'));
      expect(text, contains('STOP'));
      expect(text, contains('1m 35s'));
      expect(text, contains('me@pc'));
    });
  });

  group('running the scan', () {
    // A pretend Termux: answers discovery, answers the probe as Windows, and answers each check with its id.
    ShellRunner fakeShell({required bool windows, Set<String> flakyOnce = const <String>{}, void Function(int)? onConcurrent}) {
      var running = 0;
      final failedBefore = <String>{};
      return (command, timeout) async {
        if (command == kDiscoveryCommand) return const ShellOutput(stdout: _discovery);
        running++;
        onConcurrent?.call(running);
        try {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          final script = _scriptOf(command);
          if (!windows) return const ShellOutput(stderr: 'user@h: Permission denied (publickey).', exitCode: 255);
          if (script == kProbeScript) return const ShellOutput(stdout: 'OMNI_WIN LAB-PC PS5.1.1\n');
          final check = kScanChecks.firstWhere((c) => c.script == script);
          if (flakyOnce.contains(check.id) && failedBefore.add(check.id)) {
            return const ShellOutput(stderr: 'Connection closed by remote host', exitCode: 255);
          }
          return ShellOutput(stdout: 'output of ${check.id}\n#< CLIXML\n<Objs/>');
        } finally {
          running--;
        }
      };
    }

    test('every check runs, in parallel, and a dropped one is retried', () async {
      var peak = 0;
      final status = <String>[];
      final runner = WindowsScanRunner(
        shell: fakeShell(windows: true, flakyOnce: <String>{'accounts'}, onConcurrent: (n) => peak = max(peak, n)),
        workers: 5,
        retryDelay: const Duration(milliseconds: 5),
        onStatus: (t, {bool failed = false}) => status.add(t),
      );
      final out = await runner.run();
      expect(out.machine, 'LAB-PC');
      expect(out.target.destination, 'Ahmed@192.168.1.20');
      expect(out.results.length, kScanChecks.length);
      expect(out.failed, 0);
      expect(out.results.firstWhere((r) => r.check.id == 'accounts').attempts, 2);
      expect(out.results.firstWhere((r) => r.check.id == 'sysinfo').output, 'output of sysinfo');
      expect(peak, greaterThan(1));
      expect(peak, lessThanOrEqualTo(5 + 4)); // up to 5 checks, plus discovery probes that run together first
      expect(status.any((s) => s.contains('Connected to LAB-PC')), isTrue);
    });

    test('ten workers run more at once than five', () async {
      Future<int> peakFor(int workers) async {
        var peak = 0;
        final runner = WindowsScanRunner(
          shell: fakeShell(windows: true, onConcurrent: (n) => peak = max(peak, n)),
          workers: workers,
          retryDelay: const Duration(milliseconds: 5),
          checks: kScanChecks.take(20).toList(),
        );
        await runner.run();
        return peak;
      }

      final five = await peakFor(5);
      final ten = await peakFor(10);
      expect(ten, greaterThan(five));
    });

    test('when nothing reaches a Windows PC the reason is given', () async {
      final runner = WindowsScanRunner(shell: fakeShell(windows: false), workers: 5);
      await expectLater(
        runner.run(),
        throwsA(isA<ScanFailure>().having((e) => e.message, 'message', allOf(contains('refused the login'), contains('Ahmed@192.168.1.20')))),
      );
    });

    test('a typed address is used when none was found', () async {
      var asked = 0;
      final shell = (String command, int timeout) async {
        if (command == kDiscoveryCommand) return const ShellOutput(stdout: '@@SSH_BIN\n/bin/ssh\n@@PROCS\n@@END\n');
        final script = _scriptOf(command);
        if (script == kProbeScript && command.contains('Bob@10.1.1.1') && command.contains('-p 2200')) {
          return const ShellOutput(stdout: 'OMNI_WIN TYPED-PC PS7.4\n');
        }
        return ShellOutput(stdout: 'ok');
      };
      final runner = WindowsScanRunner(
        shell: shell,
        workers: 5,
        checks: kScanChecks.take(3).toList(),
        askTarget: (why) async {
          asked++;
          return 'Bob@10.1.1.1:2200';
        },
      );
      final out = await runner.run();
      expect(asked, 1);
      expect(out.machine, 'TYPED-PC');
      expect(out.target.port, 2200);
    });

    test('a missing ssh program stops the scan with a clear message', () async {
      final runner = WindowsScanRunner(
        shell: (c, t) async => const ShellOutput(stdout: '@@SSH_BIN\nmissing\n@@END\n'),
        workers: 5,
      );
      await expectLater(runner.run(), throwsA(isA<ScanFailure>().having((e) => e.message, 'message', contains('pkg install openssh'))));
    });

    test('stopping cancels the checks that are left', () async {
      late WindowsScanRunner runner;
      var started = 0;
      runner = WindowsScanRunner(
        shell: (command, timeout) async {
          if (command == kDiscoveryCommand) return const ShellOutput(stdout: _discovery);
          final script = _scriptOf(command);
          if (script == kProbeScript) return const ShellOutput(stdout: 'OMNI_WIN LAB-PC PS5.1.1\n');
          started++;
          if (started == 2) runner.stop();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return const ShellOutput(stdout: 'done');
        },
        workers: 5,
        retryDelay: const Duration(milliseconds: 5),
      );
      final out = await runner.run();
      expect(out.stopped, isTrue);
      expect(started, lessThan(kScanChecks.length));
    });
  });
}
