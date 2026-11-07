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

  /// Model-selected packages must match this allowlist before any package-manager command runs.
  static const Map<String, String> installablePackages = <String, String>{
    'python': 'Python runtime', 'git': 'Git version control',
    'curl': 'HTTP client', 'wget': 'HTTP downloader', 'jq': 'JSON processor',
    'nmap': 'Network mapper', 'whois': 'WHOIS client', 'dnsutils': 'DNS utilities',
    'openssl': 'TLS utilities', 'netcat-openbsd': 'Netcat',
    'rust': 'Rust toolchain', 'golang': 'Go toolchain', 'nodejs-lts': 'Node.js LTS',
    'php': 'PHP runtime', 'ruby': 'Ruby runtime', 'clang': 'C/C++ compiler',
    'make': 'Build utility', 'proot-distro': 'Debian/Ubuntu userspace manager',
  };

  static const Map<String, List<String>> packageExecutables = <String, List<String>>{
    'python': <String>['python', 'python3'],
    'git': <String>['git'],
    'curl': <String>['curl'],
    'wget': <String>['wget'],
    'jq': <String>['jq'],
    'nmap': <String>['nmap'],
    'whois': <String>['whois'],
    'dnsutils': <String>['dig'],
    'openssl': <String>['openssl'],
    'netcat-openbsd': <String>['nc', 'netcat'],
    'rust': <String>['rustc'],
    'golang': <String>['go'],
    'nodejs-lts': <String>['node', 'npm'],
    'php': <String>['php'],
    'ruby': <String>['ruby'],
    'clang': <String>['clang'],
    'make': <String>['make'],
    'proot-distro': <String>['proot-distro'],
  };

  Future<bool> isInstalled() async {
    try {
      return await _channel.invokeMethod<bool>('isInstalled') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String> version() async {
    return (await _channel.invokeMethod<String>('getVersion'))?.trim() ?? '';
  }

  Future<bool> supportsRunCommandResult() async {
    try {
      final value = await version();
      final parts = RegExp(r'\d+').allMatches(value).take(2)
          .map((match) => int.tryParse(match.group(0)!) ?? 0).toList();
      if (parts.length < 2) return false;
      return parts[0] > 0 || (parts[0] == 0 && parts[1] >= 109);
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

  /// Discovers common CLI tools without modifying the Termux environment.
  Future<List<Map<String, String>>> discoverTools() async {
    const names = <String>['python', 'python3', 'pip', 'pip3', 'git', 'curl', 'wget', 'jq',
      'nmap', 'whois', 'dig', 'openssl', 'nc', 'rustc', 'go', 'node', 'npm', 'php', 'ruby',
      'clang', 'make', 'subfinder', 'amass', 'httpx', 'nuclei', 'ffuf', 'feroxbuster', 'nikto', 'sqlmap',
      'proot-distro', 'mitmproxy', 'mitmdump', 'mitmweb'];
    final quoted = names.map((name) => "'$name'").join(' ');
    final command = 'for t in $quoted; do p=\$(command -v "\$t" 2>/dev/null || true); '
        'if [ -n "\$p" ]; then v=\$("\$p" --version 2>&1 | head -n 1); '
        "printf '%s\\t%s\\t%s\\n' \"\$t\" \"\$p\" \"\$v\"; fi; done";
    final result = await run(command, timeout: const Duration(seconds: 45));
    final exitCode = result['exitCode'];
    final nativeError = result['err'];
    final errorText = (result['errmsg'] ?? '').toString();
    if ((exitCode is num && exitCode.toInt() != 0) ||
        errorText.isNotEmpty ||
        (nativeError is num && nativeError.toInt() != -1)) {
      throw StateError(errorText.isNotEmpty ? errorText : 'Termux discovery command failed (exit: $exitCode, err: $nativeError).');
    }
    final stdout = (result['stdout'] ?? '').toString();
    final tools = <Map<String, String>>[];
    for (final line in stdout.split('\n')) {
      final parts = line.split('\t');
      if (parts.length < 2 || parts.first.trim().isEmpty) continue;
      tools.add(<String, String>{'name': parts[0].trim(), 'path': parts[1].trim(),
        'version': parts.length > 2 ? parts.sublist(2).join(' ').trim() : ''});
    }
    return tools;
  }

  /// Installs only package identifiers from [installablePackages].
  Future<Map<String, dynamic>> installPackages(List<String> packageIds) async {
    final unique = packageIds.toSet().toList(growable: false);
    if (unique.isEmpty) throw ArgumentError('No packages were selected.');
    final invalid = unique.where((id) => !installablePackages.containsKey(id)).toList();
    if (invalid.isNotEmpty) throw ArgumentError('Unsupported Termux packages: ${invalid.join(', ')}');
    final command = 'pkg install -y ${unique.join(' ')}';
    return run(command, timeout: const Duration(minutes: 5));
  }

  /// Runs [command] with `bash -lc` in Termux and returns combined status text (stdout, stderr, exit
  /// code). Output is truncated by Termux itself around 100KB. Throws a PlatformException with a
  /// human-readable message on anything that stops the command from running at all.
  Future<Map<String, dynamic>> run(String command, {String? workdir, Duration timeout = const Duration(seconds: 60)}) async {
    if (!await supportsRunCommandResult()) {
      throw StateError('Termux 0.109 or newer is required for command result callbacks.');
    }
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('run', <String, dynamic>{
      'command': command,
      if (workdir != null && workdir.trim().isNotEmpty) 'workdir': workdir.trim(),
      'timeoutMs': timeout.inMilliseconds,
    });
    return (r ?? const <Object?, Object?>{}).map((k, v) => MapEntry(k.toString(), v));
  }
}
