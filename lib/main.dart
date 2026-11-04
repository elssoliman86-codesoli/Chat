import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'data/services.dart';
import 'tools/browser_service.dart';
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
          builder: (context, child) => Stack(fit: StackFit.expand, children: [
            child ?? const SizedBox.shrink(),
            // A one-pixel browser the assistant uses to read pages that need JavaScript.
            Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: IgnorePointer(
                child: Builder(builder: (_) {
                  BrowserService.instance.attached = true;
                  return WebViewWidget(controller: BrowserService.instance.controller);
                }),
              ),
            ),
          ]),
        );
      },
    );
  }
}
