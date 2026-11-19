import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'glass/glass.dart';

/// What a broken widget shows instead of a grey or black box: the actual error, readable.
Widget readableErrorBox(FlutterErrorDetails details) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Container(
      color: const Color(0xFF3B0A0A),
      padding: const EdgeInsets.all(8),
      alignment: Alignment.topLeft,
      child: Text(
        details.exceptionAsString(),
        style: const TextStyle(color: Color(0xFFFFB4AB), fontSize: 12, decoration: TextDecoration.none, fontWeight: FontWeight.normal),
      ),
    ),
  );
}

/// Shown when the app cannot even load its saved data, so the person sees what is wrong instead of a black
/// screen, can copy it, retry, or (after confirming) start from scratch.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  Future<void> _wipe() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (_) {}
    try {
      final base = await getApplicationDocumentsDirectory();
      final chats = Directory('${base.path}/chats');
      if (await chats.exists()) await chats.delete(recursive: true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Builder(
        builder: (context) => Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Omni Chat could not start', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('Your saved data could not be loaded. This is the error — copy it and send it so it can be fixed.'),
                const SizedBox(height: 14),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFF1B1B1F), borderRadius: BorderRadius.circular(10)),
                    child: SingleChildScrollView(child: SelectableText(error, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
                  ),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: FilledButton(onPressed: onRetry, child: const Text('Try again')),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: error));
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error copied')));
                      },
                      child: const Text('Copy error'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => GlassDialog(
                          title: const Text('Erase everything?'),
                          content: const Text('This deletes all chats, providers, keys and settings on this phone, then starts fresh.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Erase')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await _wipe();
                        onRetry();
                      }
                    },
                    child: const Text('Erase all app data and start fresh', style: TextStyle(color: Color(0xFFFF8A80))),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
