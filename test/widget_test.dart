import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/ui/message_view.dart';

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
}
