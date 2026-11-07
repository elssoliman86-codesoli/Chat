import 'dart:convert';

enum ScopeDecision { allow, deny, needsReview }

class ScopeEvaluation {
  const ScopeEvaluation(this.decision, this.reason);
  final ScopeDecision decision;
  final String reason;
  bool get allowed => decision == ScopeDecision.allow;
}

/// A conservative policy snapshot. Parsing policy text never grants authorization by itself:
/// the user must review and explicitly confirm the extracted scope before active testing.
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

  /// Extracts only explicit host-like entries from common HackerOne policy lines.
  /// It deliberately does not infer related domains, API hosts, mobile backends, or vendors.
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
      final candidate = line
        .replaceFirst(RegExp(r'^[\s>*+\-•]+'), '')
        .replaceAll(RegExp(r'[`*_]'), '')
        .trim();
      final match = RegExp(r'^(\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::\d+)?/?$', caseSensitive: false)
        .firstMatch(candidate);
      if (match == null) continue;
      final host = candidate.replaceFirst(RegExp(r'/:?\d+$'), '').replaceAll(RegExp(r'/$'), '').toLowerCase();
      if (!host.contains('.')) continue;
      (outSection ? excluded : allowed).add(host);
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
      return const ScopeEvaluation(
        ScopeDecision.needsReview,
        'The policy must be reviewed and the extracted scope explicitly confirmed before active testing.',
      );
    }
    return const ScopeEvaluation(ScopeDecision.allow, 'Target is explicitly in scope.');
  }

  static String? _host(String value) {
    final input = value.trim();
    if (input.isEmpty) return null;
    final uri = Uri.tryParse(input.contains('://') ? input : 'https://$input');
    final host = uri?.host.toLowerCase();
    if (host == null || host.isEmpty || !host.contains('.') ||
        host.contains('..') || host.contains(' ')) return null;
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
