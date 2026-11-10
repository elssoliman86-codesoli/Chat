import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/ui/message_view.dart';
import 'package:omni_chat/ui/plan_banner.dart';
import 'package:omni_chat/ui/steps_card.dart';

void main() {
  testWidgets('messages render', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          MessageView(message: ChatMessage(role: 'user', text: 'Hello there'), streaming: false),
          MessageView(message: ChatMessage(role: 'assistant', text: 'Hi **friend**'), streaming: false),
        ]),
      ),
    ));
    expect(find.text('Hello there'), findsOneWidget);
    expect(find.textContaining('friend'), findsWidgets);
  });

  testWidgets('a long run of steps scrolls inside the card instead of growing without limit', (tester) async {
    final calls = [for (var i = 0; i < 12; i++) ToolCall(id: 'c$i', name: 'web_search', args: {'query': 'q$i'})];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StepsCard(calls: calls, resultOf: (_) => 'done', live: false),
      ),
    ));
    // Collapsed by default: none of the individual step rows are built yet.
    expect(find.textContaining('q0'), findsNothing);
    await tester.tap(find.text('12 steps'));
    // Pump a single frame rather than pumpAndSettle: the neon arrow between finished steps
    // animates forever (AnimationController..repeat()), which would never let pumpAndSettle finish.
    await tester.pump();
    // Open now: the long list is capped and scrollable rather than filling the whole screen.
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(find.text('q0'), findsOneWidget);
  });

  testWidgets('a short run of steps shows in full without a scrollbar', (tester) async {
    final calls = [for (var i = 0; i < 3; i++) ToolCall(id: 'c$i', name: 'web_search', args: {'query': 'q$i'})];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StepsCard(calls: calls, resultOf: (_) => 'done', live: false),
      ),
    ));
    await tester.tap(find.text('3 steps'));
    await tester.pump();
    expect(find.byType(Scrollbar), findsNothing);
    expect(find.text('q0'), findsOneWidget);
  });

  testWidgets('the plan banner shows the current step collapsed and a full checklist when tapped', (tester) async {
    final call = ToolCall(id: 'p1', name: 'set_plan', args: {
      'steps': ['Open the folder', 'Read every file', 'Fix the bug'],
      'current': 1,
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlanBanner(call: call))));
    expect(find.textContaining('Step 2 of 3'), findsOneWidget);
    expect(find.text('Open the folder'), findsNothing);
    await tester.tap(find.textContaining('Step 2 of 3'));
    await tester.pump();
    expect(find.text('Open the folder'), findsOneWidget);
    expect(find.text('Read every file'), findsOneWidget);
    expect(find.text('Fix the bug'), findsOneWidget);
  });

  testWidgets('the plan banner shows completion once every step is past current', (tester) async {
    final call = ToolCall(id: 'p2', name: 'set_plan', args: {
      'steps': ['a', 'b'],
      'current': 2,
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlanBanner(call: call))));
    expect(find.textContaining('Plan complete — 2/2'), findsOneWidget);
  });

  testWidgets('the skill-load banner moves from reading to loaded and then dismisses itself', (tester) async {
    Widget build(String? result) => MaterialApp(home: Scaffold(body: SkillLoadBanner(name: 'canva-invoices', result: result)));
    await tester.pumpWidget(build(null));
    expect(find.textContaining('Reading skill'), findsOneWidget);
    await tester.pumpWidget(build('Skill "canva-invoices" loaded.'));
    await tester.pump();
    expect(find.textContaining('Loaded skill'), findsOneWidget);
    // It fades itself out a couple of seconds after loading rather than staying on screen forever.
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('Loaded skill'), findsNothing);
  });
}
