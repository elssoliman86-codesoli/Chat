import 'package:flutter/widgets.dart';

import '../core/models.dart';
import 'model_checker.dart';
import 'services.dart';

/// Which models the automatic check covers: every model that was tested before, plus each provider's
/// selected model and the current chat's model, so a fresh install still checks what is actually in use.
List<(ProviderConfig, String)> autoHealthJobs(List<ProviderConfig> providers, {ProviderConfig? currentProvider, String currentModel = '', int limit = 150}) {
  final seen = <String>{};
  final jobs = <(ProviderConfig, String)>[];
  void add(ProviderConfig p, String m) {
    if (m.isEmpty || jobs.length >= limit) return;
    if (seen.add('${p.id}|$m')) jobs.add((p, m));
  }

  if (currentProvider != null) add(currentProvider, currentModel);
  for (final p in providers) {
    add(p, p.model);
  }
  for (final p in providers) {
    for (final m in p.health.keys) {
      add(p, m);
    }
  }
  return jobs;
}

/// Refreshes the model health (HTTP 200) results by itself every time the app opens, and again when it
/// comes back to the foreground after a while, so the list and the automatic fallback never rely on a
/// stale test.
class AutoHealth with WidgetsBindingObserver {
  AutoHealth._();
  static final AutoHealth instance = AutoHealth._();

  static const Duration minGap = Duration(minutes: 10);
  DateTime? _last;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    refresh(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _last != null && now.difference(_last!) < minGap) return;
    if (checker.running) return;
    _last = now;
    try {
      final c = store.current;
      final jobs = autoHealthJobs(store.providers, currentProvider: c == null ? null : store.providerById(c.providerId), currentModel: c?.model ?? '');
      await checker.run(jobs, keepOnNoAnswer: true);
    } catch (_) {}
  }
}
