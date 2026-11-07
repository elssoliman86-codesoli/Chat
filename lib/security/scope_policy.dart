import 'dart:convert';

enum ScopeDecision { allow, deny, needsReview }

class ScopeEvaluation {
  const ScopeEvaluation(this.decision, this.reason);
  final ScopeDecision decision;
  final String reason;
  bool get allowed => decision == ScopeDecision.allow;
}

/// A conservative policy snapshot. Parsing never grants authorization by itself.
/// Active testing requires policy review and explicit user confirmation.
class ScopePolicy {
  ScopePolicy({
    required this.source,
    required this.inScope,
    this.outOfScope = const <String>{},
    this.reviewed = false,
    this.userConfirmed = false,
  });

  final String source;
  final Set<String> inScope;
  final Set<String> outOfScope;
  bool reviewed;
  bool userConfirmed;

  factory ScopePolicy.fromJson(Map<String, dynamic> json) => ScopePolicy(
    source: json['source'] as String? ?? '',
    inScope: (json['inScope'] as List?)?.whereType<String>().toSet() ?? <String>{},
    outOfScope: (json['outOfScope'] as List?)?.whereType<String>().toSet() ?? <String>{},
    reviewed: json['reviewed'] == true,
    userConfirmed: json['userConfirmed'] == true,
  );

  Map<String, dynamic> toJson() => {
    'source': source,
    'inScope': inScope.toList()..sort(),
    'outOfScope': outOfScope.toList()..sort(),
    'reviewed': reviewed,
    'userConfirmed': userConfirmed,
  };

  /// Extracts only explicit host entries from plain lists or Markdown asset tables.
  static ScopePolicy parse(String text, {String source = ''}) {
    final allowed = <String>{};
    final excluded = <String>{};
    var outSection = false;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower.contains('out of scope') || lower.contains('excluded assets')) {
        outSection = true;
      } else if (lower.contains('in scope') || lower.contains('eligible assets')) {
        outSection = false;
      }
      var candidate = line.replaceFirst(RegExp(r'^[\s>+\-•]+'), '').trim();
      candidate = candidate.replaceFirst(RegExp(r'^\*\s+'), '').replaceAll(String.fromCharCode(96), '');
      if (candidate.startsWith('**') && candidate.endsWith('**') && candidate.length > 4) {
        candidate = candidate.substring(2, candidate.length - 2);
      }
      final cells = line.contains('|') ? line.split('|') : <String>[candidate];
      for (var cell in cells) {
        cell = cell.trim().replaceAll(String.fromCharCode(96), '').replaceAll('<', '').replaceAll('>', '');
        final link = RegExp(r'^\[([^\]]+)\]\([^)]*\)$').firstMatch(cell);
        if (link != null) cell = link.group(1)!.trim();
        cell = cell.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '').split('/').first;
        final match = RegExp(r'^(\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::\d+)?$', caseSensitive: false).firstMatch(cell);
        if (match == null) continue;
        final host = cell.replaceFirst(RegExp(r':\d+$'), '').toLowerCase();
        final isIpv4 = RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}$').hasMatch(host);
        if (!host.contains('.') || isIpv4 || host.contains(':')) continue;
        (outSection ? excluded : allowed).add(host);
      }
    }
    return ScopePolicy(source: source, inScope: allowed, outOfScope: excluded);
  }

  ScopeEvaluation evaluate(String target, {required bool activeOperation}) {
    final host = _host(target);
    if (host == null) {
      return const ScopeEvaluation(ScopeDecision.deny, 'Target is not a valid hostname or URL.');
    }
    if (outOfScope.any((entry) => _matches(host, entry))) {
      return ScopeEvaluation(ScopeDecision.deny, '$host matches an explicitly out-of-scope asset.');
    }
    if (!inScope.any((entry) => _matches(host, entry))) {
      return ScopeEvaluation(ScopeDecision.deny, '$host is not explicitly listed in scope.');
    }
    if (activeOperation && (!reviewed || !userConfirmed)) {
      return const ScopeEvaluation(ScopeDecision.needsReview,
        'The policy must be reviewed and the extracted scope explicitly confirmed before active testing.');
    }
    return const ScopeEvaluation(ScopeDecision.allow, 'Target is explicitly in scope.');
  }

  static String? _host(String value) {
    final input = value.trim();
    if (input.isEmpty) return null;
    final uri = Uri.tryParse(input.contains('://') ? input : 'https://$input');
    final host = uri?.host.toLowerCase();
    if (host == null || host.isEmpty || !host.contains('.') || host.contains('..') || host.contains(' ') ||
        host.contains(':') || RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}$').hasMatch(host)) {
      return null;
    }
    return host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  }

  static bool _matches(String host, String rule) {
    final normalized = rule.toLowerCase().trim();
    if (normalized.startsWith('*.')) {
      final suffix = normalized.substring(2);
      return host != suffix && host.endsWith('.$suffix');
    }
    return host == normalized;
  }
}
