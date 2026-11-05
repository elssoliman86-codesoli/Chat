import 'package:flutter/services.dart';

/// Keeps the app alive while the assistant works, so a long task (a big project, a browser job)
/// keeps running when the person switches to another app. Shows a small ongoing notification.
class BackgroundWork {
  static const MethodChannel _channel = MethodChannel('omni/keepalive');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
