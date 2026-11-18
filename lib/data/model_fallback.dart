import '../core/models.dart';

/// The HTTP status inside an error message of the form "HTTP 429: ...", or null.
int? failureStatus(String message) {
  final m = RegExp(r'HTTP (\d{3})').firstMatch(message);
  return m == null ? null : int.tryParse(m.group(1) ?? '');
}

const List<String> _network = <String>[
  'socketexception', 'failed host lookup', 'connection closed', 'connection reset', 'connection refused', 'connection terminated',
  'timeoutexception', 'timed out', 'clientexception', 'handshake', 'network is unreachable', 'broken pipe', 'software caused connection abort',
];

const List<String> _quotaWords = <String>[
  'quota', 'credit', 'insufficient', 'billing', 'exceeded', 'out of tokens', 'balance', 'rate limit', 'rate-limit', 'too many requests',
  'overloaded', 'no longer available', 'model not found', 'does not exist', 'unavailable', 'exhausted', 'payment', 'subscription',
];

/// Whether a failed request means THIS MODEL cannot answer right now (out of tokens or credit, rate
/// limited, bad key, model gone, provider down) so another model should take over — as opposed to a
/// dropped connection or timeout, which says nothing about the model and must not trigger a switch.
bool isModelFailure(String message) {
  final m = message.toLowerCase();
  final status = failureStatus(message);
  if (status != null) {
    if (status == 401 || status == 402 || status == 403 || status == 404 || status == 429 || status >= 500) return true;
    return _quotaWords.any(m.contains);
  }
  if (_network.any(m.contains)) return false;
  return _quotaWords.any(m.contains);
}

/// Whether the failure is about the whole account or provider (credit, key, permission), in which case
/// the replacement should come from another provider.
bool isAccountFailure(String message) {
  final m = message.toLowerCase();
  final status = failureStatus(message);
  if (status == 401 || status == 402 || status == 403) return true;
  return const ['credit', 'billing', 'balance', 'insufficient', 'payment', 'subscription', 'quota', 'out of tokens'].any(m.contains);
}

String candidateKey(ProviderConfig p, String model) => '${p.id}|$model';

/// Models that answered the last health check with HTTP 2xx and have not been tried yet, best first:
/// the same provider's other models first, or other providers first after an account-level failure.
List<(ProviderConfig, String)> fallbackCandidates(
  List<ProviderConfig> providers,
  ProviderConfig current,
  Set<String> tried, {
  bool otherProviderFirst = false,
}) {
  final same = <(ProviderConfig, String)>[];
  final other = <(ProviderConfig, String)>[];
  for (final p in providers) {
    for (final m in <String>{if (p.model.isNotEmpty) p.model, ...p.models}) {
      final status = p.health[m];
      if (status == null || status < 200 || status >= 300 || tried.contains(candidateKey(p, m))) continue;
      (p.id == current.id ? same : other).add((p, m));
    }
  }
  return otherProviderFirst ? <(ProviderConfig, String)>[...other, ...same] : <(ProviderConfig, String)>[...same, ...other];
}
