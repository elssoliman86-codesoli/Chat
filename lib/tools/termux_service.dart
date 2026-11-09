import 'package:flutter/services.dart';

/// What was found out about the installed Termux app: whether it is installed, which version, and
/// whether that exact build can support the RUN_COMMAND automation this app needs at all (separate
/// from whether permission has been granted yet).
class TermuxDiagnosis {
  const TermuxDiagnosis({
    required this.installed,
    required this.versionName,
    required this.permissionDeclared,
    required this.serviceExists,
    required this.hasPermission,
    required this.supportsAutomation,
  });

  final bool installed;
  final String versionName;

  /// False means this build is too old to even declare the RUN_COMMAND permission — a dead end no
  /// matter how many times the permission is granted.
  final bool permissionDeclared;

  /// False means this build never shipped the RunCommandService component this app calls into.
  final bool serviceExists;
  final bool hasPermission;

  /// True only when both the permission and the service exist in this exact build, i.e. it is at
  /// least as new as the one Termux has shipped on F-Droid/GitHub since RUN_COMMAND was added.
  final bool supportsAutomation;
}

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

  /// Shows the system permission dialog. Returns once answered (granted or denied). Android stops
  /// showing this dialog at all after a few denials, with no way for the app to tell — if tapping the
  /// in-app button visibly does nothing, that is almost always this, and openAppSettings() below is the
  /// only remaining way in.
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's own system settings page, where the person can grant the permission by hand when
  /// Android has stopped showing the request dialog.
  Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } catch (_) {}
  }

  /// Distinguishes "Termux is installed but hasn't granted the permission yet" from "this exact
  /// Termux build cannot support RUN_COMMAND at all" (old, long-unmaintained builds, most commonly the
  /// one that used to be on the Play Store, predate the permission and service this needs entirely —
  /// no amount of granting permission fixes that; the terminal itself still works fine by hand).
  Future<TermuxDiagnosis> diagnose() async {
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('diagnose');
      final m = (r ?? const <Object?, Object?>{}).map((k, v) => MapEntry(k.toString(), v));
      return TermuxDiagnosis(
        installed: m['installed'] as bool? ?? false,
        versionName: m['versionName'] as String? ?? '',
        permissionDeclared: m['permissionDeclared'] as bool? ?? false,
        serviceExists: m['serviceExists'] as bool? ?? false,
        hasPermission: m['hasPermission'] as bool? ?? false,
        supportsAutomation: m['supportsAutomation'] as bool? ?? false,
      );
    } catch (_) {
      return const TermuxDiagnosis(
        installed: false,
        versionName: '',
        permissionDeclared: false,
        serviceExists: false,
        hasPermission: false,
        supportsAutomation: false,
      );
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
