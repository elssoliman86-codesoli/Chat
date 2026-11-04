import 'package:flutter/material.dart';

import 'data/services.dart';
import 'ui/chat_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const OmniChatApp());
}

class OmniChatApp extends StatelessWidget {
  const OmniChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final mode = switch (store.settings.themeMode) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        };
        return MaterialApp(
          title: 'Omni Chat',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: const ChatScreen(),
        );
      },
    );
  }
}
