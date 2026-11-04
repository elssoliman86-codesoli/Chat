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
    return ValueListenableBuilder<String>(
      valueListenable: store.themeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Omni Chat',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          themeMode: themeModeFor(mode),
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark, emerald: mode == 'emerald'),
          home: const ChatScreen(),
          builder: (context, child) => AppBackdrop(emerald: mode == 'emerald', child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
