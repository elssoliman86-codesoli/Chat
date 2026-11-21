import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'data/auto_health.dart';
import 'data/services.dart';
import 'downloads/download_manager.dart';
import 'downloads/download_task.dart' show fileNameFrom;
import 'net/proxy_service.dart';
import 'tools/browser_service.dart';
import 'tools/ftp_service.dart';
import 'tools/web_native.dart';
import 'ui/chat_screen.dart';
import 'ui/downloads_screen.dart';
import 'ui/startup_error.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A broken widget shows its real error instead of a grey/black box.
  ErrorWidget.builder = readableErrorBox;
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('Flutter error: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
    return true;
  };
  await _start();
}

Future<void> _start() async {
  try {
    await store.load().timeout(const Duration(seconds: 20));
  } catch (e, s) {
    runApp(StartupErrorApp(error: '$e\n\n$s', onRetry: _start));
    return;
  }
  // Before anything touches the network: route it through the chosen proxy or Tor.
  ProxyService.instance.install();
  try {
    await ProxyService.instance.apply(store.settings).timeout(const Duration(seconds: 5));
  } catch (_) {}
  if (store.settings.localBrowser.isNotEmpty) {
    unawaited(BrowserService.instance.useIdentity(
      package: store.settings.localBrowser,
      label: store.settings.localBrowserName,
      version: store.settings.localBrowserVersion,
    ));
  }
  unawaited(FtpService.instance.ensureStartedIfEnabled(store.settings).catchError((Object _) {}));
  runApp(const OmniChatApp());
  unawaited(DownloadManager.instance.load());
  // A file link tapped in the built-in browser: ask where to save it, then fetch it in parallel.
  WebNative.downloads.listen((r) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null || r.url.startsWith('blob:') || r.url.startsWith('data:')) return;
    unawaited(showDownloadPrompt(
      ctx,
      url: r.url,
      nameHint: fileNameFrom(disposition: r.disposition, url: r.url, mime: r.mime),
      headers: DownloadManager.headersFor(cookie: r.cookie, userAgent: r.userAgent, referer: r.referer),
    ));
  });
  // Re-test the known models in the background each time the app opens — only after the first screen is
  // up, so a slow network can never delay or break the start.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future<void>.delayed(const Duration(seconds: 2), AutoHealth.instance.start);
  });
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
