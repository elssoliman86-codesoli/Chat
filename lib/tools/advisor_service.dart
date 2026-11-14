import 'dart:async';

import '../core/models.dart';
import '../llm/llm.dart';

/// A second, separately-configured model the assistant can consult mid-task for a second opinion —
/// Settings > Plugins > Assistant model. One-shot, like ImageReader.viaHelper: no back-and-forth
/// conversation of its own, just a single question in and a single answer out, which the primary
/// model (already in its own agentic loop) reads as an ordinary tool result and acts on itself.
class AdvisorService {
  static Future<String> ask(String question, ProviderConfig provider, String model) async {
    final client = createClient(provider);
    final abort = AbortHandle();
    final out = StringBuffer();
    final request = LlmRequest(
      system: 'You are a technical advisor being consulted mid-task by another AI agent that is stuck or unsure, not by '
          'the end user directly. You are given the real context it ran into (a command, an error, a decision it is '
          'unsure about) and asked for your own read on it. Give a direct, concrete answer: what you think is actually '
          'going on, and if more than one step is needed to resolve it, list the steps in order as plain numbered '
          'text so the other agent can carry them out one at a time. Do not ask the other agent clarifying questions '
          'unless the context given is genuinely too thin to say anything useful — it cannot act on a question back, '
          'only on a direct answer.',
      messages: [ChatMessage(role: 'user', text: question)],
      model: model,
    );
    try {
      await for (final e in client.stream(request, abort).timeout(const Duration(seconds: 90))) {
        if (e is TextDelta) out.write(e.text);
      }
    } finally {
      abort.abort();
    }
    final text = out.toString().trim();
    return text.isEmpty ? 'The advisor model gave an empty reply.' : text;
  }
}
