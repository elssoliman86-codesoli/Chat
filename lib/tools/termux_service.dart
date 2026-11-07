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

  /// Discovers common CLI tools without modifying the Termux environment.
  Future<List<Map<String, String>>> discoverTools() async {
    const names = <String>['python', 'python3', 'pip', 'pip3', 'git', 'curl', 'wget', 'jq',
      'nmap', 'whois', 'dig', 'openssl', 'nc', 'rustc', 'go', 'node', 'npm', 'php', 'ruby',
      'clang', 'make', 'subfinder', 'amass', 'httpx', 'nuclei', 'ffuf', 'feroxbuster', 'nikto', 'sqlmap',
      'proot-distro', 'mitmproxy', 'mitmdump', 'mitmweb'];
    final quoted = names.map((name) => "'$name'").join(' ');
    final command = 'for t in $quoted; do p=$(command -v "$t" 2>/dev/null || true); '
        'if [ -n "$p" ]; then v=$("$p" --version 2>&1 | head -n 1); '
        "printf '%s\\t%s\\t%s\\n' \"$t\" \"$p\" \"$v\"; fi; done";
    final result = await run(command, timeout: const Duration(seconds: 45));
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
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('run', <String, dynamic>{
      'command': command,
      if (workdir != null && workdir.trim().isNotEmpty) 'workdir': workdir.trim(),
      'timeoutMs': timeout.inMilliseconds,
    });
    return (r ?? const <Object?, Object?>{}).map((k, v) => MapEntry(k.toString(), v));
  }
}
