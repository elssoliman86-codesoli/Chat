import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/tools/termux_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('omni/termux');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'run') {
        final command = (call.arguments as Map)['command'] as String;
        if (command.contains('pkg install')) {
          return <String, dynamic>{'stdout': 'installed', 'stderr': '', 'exitCode': 0};
        }
        return <String, dynamic>{
          'stdout': 'python\t/data/data/com.termux/files/usr/bin/python\tPython 3.12.1\ngit\t/data/data/com.termux/files/usr/bin/git\tgit version 2.45.0',
          'stderr': '',
          'exitCode': 0,
        };
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('discovers installed tools and parses executable paths and versions', () async {
    final tools = await TermuxService.instance.discoverTools();
    expect(tools, hasLength(2));
    expect(tools.first['name'], 'python');
    expect(tools.first['path'], '/data/data/com.termux/files/usr/bin/python');
    expect(tools.first['version'], 'Python 3.12.1');
    expect(calls.single.method, 'run');
    expect((calls.single.arguments as Map)['command'], contains('command -v'));
  });

  test('installs only supported package identifiers', () async {
    final result = await TermuxService.instance.installPackages(['python', 'git']);
    expect(result['exitCode'], 0);
    expect((calls.single.arguments as Map)['command'], 'pkg install -y python git');
  });

  test('rejects arbitrary package names before invoking Termux', () async {
    expect(
      () => TermuxService.instance.installPackages(['python; rm -rf ~']),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });
}
