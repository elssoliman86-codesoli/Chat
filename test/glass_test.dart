import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/data/chat_engine.dart' show toolResultFailed;
import 'package:omni_chat/ui/glass/glass.dart';
import 'package:omni_chat/ui/glass/neon_timeline.dart';
import 'package:omni_chat/ui/steps_card.dart';
import 'package:omni_chat/ui/theme.dart';

Widget host(Widget child, {Brightness b = Brightness.dark}) => MaterialApp(
      theme: buildTheme(b),
      home: Scaffold(body: Center(child: SingleChildScrollView(child: child))),
    );

ToolCall call(String id, int at, {String name = 'web_search'}) => ToolCall(id: id, name: name, args: {'query': 'q$id'}, startedAt: at);

ChatMessage toolMsg(String id, int at, {bool failed = false, String text = 'ok'}) =>
    ChatMessage(role: 'tool', text: text, toolCallId: id, toolName: 'web_search', at: at, failed: failed);

void main() {
  group('real execution state', () {
    final calls = [call('a', 1000), call('b', 2000), call('c', 3000), call('d', 4000)];

    List<TimelineStep> build({required Map<String, ChatMessage> msgs, required bool live, String? running}) => timelineStepsFor(
          calls: calls,
          resultOf: (id) => msgs[id]?.text,
          msgOf: (id) => msgs[id],
          live: live,
          runningId: running,
        );

    test('finished, failed, running and waiting calls are told apart', () {
      final steps = build(
        msgs: {'a': toolMsg('a', 1500), 'b': toolMsg('b', 2600, failed: true, text: 'Tool failed: boom')},
        live: true,
        running: 'c',
      );
      expect(steps.map((s) => s.status).toList(), [StepStatus.completed, StepStatus.failed, StepStatus.running, StepStatus.pending]);
    });

    test('the timeline never invents progress: nothing running means nothing shows as running', () {
      final steps = build(msgs: {'a': toolMsg('a', 1500)}, live: true, running: null);
      expect(steps.where((s) => s.status == StepStatus.running), isEmpty);
      expect(steps[1].status, StepStatus.pending);
    });

    test('calls that never got a result once the turn is over were cancelled', () {
      final steps = build(msgs: {'a': toolMsg('a', 1500)}, live: false);
      expect(steps.map((s) => s.status).toList(), [StepStatus.completed, StepStatus.cancelled, StepStatus.cancelled, StepStatus.cancelled]);
      expect(steps[1].startedAt, isNull);
    });

    test('times and durations come from the recorded timestamps', () {
      final steps = build(msgs: {'a': toolMsg('a', 1500), 'b': toolMsg('b', 4200)}, live: true, running: 'c');
      expect(steps[0].startedAt!.millisecondsSinceEpoch, 1000);
      expect(steps[0].duration, const Duration(milliseconds: 500));
      // The second call really started when the first one ended or when it was requested, whichever is later.
      expect(steps[1].startedAt!.millisecondsSinceEpoch, 2000);
      expect(steps[1].duration, const Duration(milliseconds: 2200));
      expect(steps[2].startedAt!.millisecondsSinceEpoch, 4200);
      expect(steps[2].duration, isNull);
      expect(steps[3].startedAt, isNull);
    });

    test('the result text is the step detail', () {
      final steps = build(msgs: {'a': toolMsg('a', 1500, text: 'found it')}, live: false);
      expect(steps.first.details, 'found it');
    });
  });

  group('failure marking', () {
    test('only the app\'s own failure messages count as failed', () {
      expect(toolResultFailed('Tool failed: SocketException'), isTrue);
      expect(toolResultFailed('Unknown tool: nope'), isTrue);
      expect(toolResultFailed('Could not open the page: x'), isTrue);
      expect(toolResultFailed('Found 3 results'), isFalse);
      expect(toolResultFailed(''), isFalse);
    });

    test('startedAt and failed survive a JSON round trip', () {
      final c = ToolCall.fromJson(jsonDecode(jsonEncode(call('a', 1234).toJson())) as Map<String, dynamic>);
      expect(c.startedAt, 1234);
      final m = ChatMessage.fromJson(jsonDecode(jsonEncode(toolMsg('a', 1, failed: true).toJson())) as Map<String, dynamic>);
      expect(m.failed, isTrue);
      // An old save without the new fields still loads.
      final old = ToolCall.fromJson({'id': 'x', 'name': 'web_search', 'args': <String, dynamic>{}});
      expect(old.startedAt, greaterThan(0));
    });
  });

  group('themes', () {
    test('dark and light are glass themes with distinct tokens', () {
      final d = buildTheme(Brightness.dark).extension<Palette>()!;
      final l = buildTheme(Brightness.light).extension<Palette>()!;
      expect(d.glass, isTrue);
      expect(l.glass, isTrue);
      expect(d.grouped.a, 0); // pages are transparent: the scene shows through
      expect(d.surface, isNot(l.surface));
      expect(buildTheme(Brightness.dark).scaffoldBackgroundColor, Colors.transparent);
    });

    test('text keeps readable contrast against the scene', () {
      double lum(Color c) => c.computeLuminance();
      double contrast(Color a, Color b) {
        final x = lum(a), y = lum(b);
        return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
      }

      final dark = buildTheme(Brightness.dark);
      expect(contrast(dark.colorScheme.onSurface, const Color(0xFF0A1530)), greaterThan(7));
      expect(contrast(Palette.dark.secondary, const Color(0xFF0A1530)), greaterThan(4.5));
      final light = buildTheme(Brightness.light);
      expect(contrast(light.colorScheme.onSurface, const Color(0xFFDDE8FA)), greaterThan(7));
      expect(contrast(Palette.light.secondary, const Color(0xFFDDE8FA)), greaterThan(4.5));
    });
  });

  group('NeonProgressTimeline', () {
    testWidgets('shows every state with its title, description and times', (tester) async {
      final handle = tester.ensureSemantics();
      final steps = [
        TimelineStep(id: '1', title: 'Searched the web', description: 'gold price', status: StepStatus.completed, startedAt: DateTime(2026, 1, 1, 9, 5, 3), duration: const Duration(milliseconds: 2400)),
        const TimelineStep(id: '2', title: 'Read a web page', status: StepStatus.failed, details: 'Tool failed: timeout'),
        const TimelineStep(id: '3', title: 'Opened the browser', status: StepStatus.running),
        const TimelineStep(id: '4', title: 'Typed text', status: StepStatus.pending),
        const TimelineStep(id: '5', title: 'Saved a file', status: StepStatus.cancelled),
      ];
      await tester.pumpWidget(host(NeonProgressTimeline(steps: steps)));
      await tester.pump(const Duration(milliseconds: 700));
      for (final t in ['Searched the web', 'Read a web page', 'Opened the browser', 'Typed text', 'Saved a file', 'gold price']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.textContaining('09:05:03'), findsOneWidget);
      expect(find.textContaining('2.4 s'), findsOneWidget);
      expect(find.textContaining('running…'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Opened the browser, running')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Typed text, waiting')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a step with output expands to show it', (tester) async {
      await tester.pumpWidget(host(const NeonProgressTimeline(steps: [TimelineStep(id: '1', title: 'Ran Python', status: StepStatus.completed, details: 'hello output')])));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('hello output'), findsNothing);
      await tester.tap(find.text('Ran Python'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('hello output'), findsOneWidget);
    });

    testWidgets('works in the light theme too', (tester) async {
      await tester.pumpWidget(host(const NeonProgressTimeline(steps: [TimelineStep(id: '1', title: 'One', status: StepStatus.completed), TimelineStep(id: '2', title: 'Two', status: StepStatus.pending)]), b: Brightness.light));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('One'), findsOneWidget);
      expect(find.text('Two'), findsOneWidget);
    });
  });

  group('components', () {
    testWidgets('GlassButton calls back, but not when disabled or loading', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(Column(children: [
        GlassButton(label: 'Go', onPressed: () => taps++),
        const GlassButton(label: 'Off', onPressed: null),
        GlassButton(label: 'Busy', loading: true, onPressed: () => taps += 100),
      ])));
      await tester.tap(find.text('Go'));
      await tester.tap(find.text('Off'));
      await tester.tap(find.text('Busy'));
      expect(taps, 1);
    });

    testWidgets('GlassIconButton and GlassToggle respond to taps', (tester) async {
      var pressed = 0;
      var on = false;
      await tester.pumpWidget(host(StatefulBuilder(
        builder: (context, set) => Column(children: [
          GlassIconButton(icon: CupertinoIcons.plus, tooltip: 'Add', onPressed: () => pressed++),
          GlassToggle(value: on, onChanged: (v) => set(() => on = v)),
        ]),
      )));
      await tester.tap(find.byIcon(CupertinoIcons.plus));
      await tester.tap(find.byType(GlassToggle));
      await tester.pump(const Duration(milliseconds: 300));
      expect(pressed, 1);
      expect(on, isTrue);
    });

    testWidgets('GlassInput takes text and shows an error', (tester) async {
      final c = TextEditingController();
      await tester.pumpWidget(host(Padding(padding: const EdgeInsets.all(16), child: GlassInput(controller: c, hint: 'Name', errorText: 'Required'))));
      await tester.enterText(find.byType(TextField), 'hello');
      expect(c.text, 'hello');
      expect(find.text('Required'), findsOneWidget);
    });

    testWidgets('GlassStatusIndicator labels every status', (tester) async {
      await tester.pumpWidget(host(Column(children: [for (final s in GlassStatus.values) GlassStatusIndicator(status: s, showLabel: true)])));
      await tester.pump(const Duration(milliseconds: 200));
      for (final s in GlassStatus.values) {
        expect(find.text(glassStatusLabel(s)), findsOneWidget, reason: s.name);
      }
    });

    testWidgets('GlassDialog and the glass bottom sheet open and close', (tester) async {
      await tester.pumpWidget(host(Builder(
        builder: (context) => Column(children: [
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (d) => GlassDialog(title: const Text('Delete?'), content: const Text('Really?'), actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel'))]),
            ),
            child: const Text('dialog'),
          ),
          TextButton(
            onPressed: () => showGlassSheet<void>(context: context, builder: (c) => const ListTile(title: Text('Sheet item'))),
            child: const Text('sheet'),
          ),
        ]),
      )));
      await tester.tap(find.text('dialog'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Delete?'), findsOneWidget);
      expect(find.text('Really?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Delete?'), findsNothing);
      await tester.tap(find.text('sheet'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Sheet item'), findsOneWidget);
    });

    testWidgets('FrostedGlassCard shows its child and handles taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(FrostedGlassCard(blur: true, onTap: () => taps++, child: const Text('card'))));
      await tester.tap(find.text('card'));
      expect(taps, 1);
    });
  });
}
