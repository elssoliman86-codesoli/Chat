import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/ui/startup_error.dart';

void main() {
  testWidgets('the startup error screen shows the error and can retry', (tester) async {
    var retried = 0;
    await tester.pumpWidget(StartupErrorApp(error: 'FormatException: bad json\n\n#0 main', onRetry: () => retried++));
    expect(find.text('Omni Chat could not start'), findsOneWidget);
    expect(find.textContaining('FormatException: bad json'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
    expect(find.text('Copy error'), findsOneWidget);
  });

  testWidgets('a broken widget shows its error text', (tester) async {
    final box = readableErrorBox(FlutterErrorDetails(exception: StateError('boom here')));
    await tester.pumpWidget(box);
    expect(find.textContaining('boom here'), findsOneWidget);
  });
}
