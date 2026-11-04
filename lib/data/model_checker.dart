import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../llm/llm.dart';
import 'services.dart';

/// Tests models with a one-token request so the list can show which ones really answer (HTTP 200).
class ModelChecker extends ChangeNotifier {
  bool running = false;
  int done = 0;
  int total = 0;
  bool _cancel = false;

  void cancel() => _cancel = true;

  Future<void> run(List<(ProviderConfig, String)> jobs) async {
    if (running || jobs.isEmpty) return;
    running = true;
    _cancel = false;
    done = 0;
    total = jobs.length;
    notifyListeners();
    final clients = <String, LlmClient>{};
    var next = 0;
    Future<void> worker() async {
      while (!_cancel) {
        final i = next++;
        if (i >= jobs.length) return;
        final (provider, model) = jobs[i];
        final client = clients.putIfAbsent(provider.id, () => createClient(provider));
        PingResult r;
        try {
          r = await client.ping(model);
        } catch (e) {
          r = PingResult(0, e.toString(), 0);
        }
        provider.health[model] = r.status;
        // A model that rejects images will say so on the first real use; here only the status matters.
        done++;
        notifyListeners();
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    running = false;
    await store.saveProviders();
    notifyListeners();
  }
}

final ModelChecker checker = ModelChecker();
