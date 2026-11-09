import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/ui/message_view.dart';
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
}
