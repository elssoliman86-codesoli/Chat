import 'package:flutter/services.dart';

/// Runs real shell commands on the phone through Termux (a separate, free terminal app the person
/// installs themselves), using Termux's own RUN_COMMAND intent API. This is NOT a sandbox: it is the
/// person's actual Linux environment on their own device, with whatever they have installed there
/// (python, node, git, curl, compilers, ...). It only works when Termux is installed, the person has
/// granted this app the "Run commands in Termux environment" permission, and Termux's own
/// ~/.termux/termux.properties has `allow-external-apps = true` (a one-time setting only changeable
/// from inside Termux itself, not from here).
class TermuxService {
  TermuxService._();
  static final TermuxService instance = TermuxService._();

  static const MethodChannel _channel = MethodChannel('omni/termux');

  Future<bool> isInstalled() async {
    try {
      return await _channel.invokeMethod<bool>('isInstalled') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Shows the system permission dialog. Returns once answered (granted or denied).
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Runs [command] with `bash -lc` in Termux and returns combined status text (stdout, stderr, exit
  /// code). Output is truncated by Termux itself around 100KB. Throws a PlatformException with a
  /// human-readable message on anything that stops the command from running at all.
  Future<Map<String, dynamic>> run(String command, {String? workdir, Duration timeout = const Duration(seconds: 60)}) async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('run', <String, dynamic>{
      'command': command,
      if (workdir != null && workdir.trim().isNotEmpty) 'workdir': workdir.trim(),
      'timeoutMs': timeout.inMilliseconds,
    });
    return (r ?? const <Object?, Object?>{}).map((k, v) => MapEntry(k.toString(), v));
  }
}
