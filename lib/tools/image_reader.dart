import 'dart:async';

import '../core/models.dart';
import '../llm/llm.dart';
import 'browser_service.dart';
import 'tools.dart';

/// Turns an image into text for models that cannot see images.
class ImageReader {
  /// Another model that can see (for example Gemini) reads the image.
  static Future<String> viaHelper(Attachment image, ProviderConfig provider, String model) async {
    final client = createClient(provider);
    final abort = AbortHandle();
    final out = StringBuffer();
    final request = LlmRequest(
      system: 'You are an OCR and image description engine. Reply with plain text only.',
      messages: [
        ChatMessage(
          role: 'user',
          text: 'Copy ALL the text that appears in this image exactly as written, in its original language and direction '
              '(Arabic, English, Russian and others), keeping line breaks. If there is no text, write "No text". '
              'Then add a line starting with "Description:" that says in one or two sentences what the image shows.',
          attachments: [image],
        ),
      ],
      model: model,
    );
    try {
      await for (final e in client.stream(request, abort).timeout(const Duration(seconds: 90))) {
        if (e is TextDelta) out.write(e.text);
      }
    } finally {
      abort.abort();
    }
    return out.toString().trim();
  }

  /// Google Lens in the built-in browser. Experimental: it works only while Google's page looks as expected.
  static Future<String> viaLens(Attachment image, ToolHost host) async {
    final b = BrowserService.instance;
    b.show(address: null);
    await b.open('https://lens.google.com/');
    final started = await b.uploadFile(image.path);
    var reached = false;
    for (var i = 0; i < 30 && started; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      final u = b.url.value;
      if (u.contains('lens.google.com/search') || u.contains('vsrid=') || u.contains('lens.google.com/uploadbyurl')) {
        reached = true;
        break;
      }
    }
    if (!reached) {
      final answer = await host.askUser(
          'Finish the Google Lens upload in the browser panel: accept the cookie notice if it appears and choose the photo '
          '"${image.name}". Tap Done when the results are showing.');
      if (answer.startsWith('The person cancelled')) throw Exception('Cancelled');
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    // Switch to the "Text" view when the page has that tab.
    await b.evalJs(r'''
(function(){var t=[].slice.call(document.querySelectorAll('button,a,div[role=tab],div[role=button],span')).filter(function(e){
 var x=((e.innerText||'')+'').trim();return /^(text|النص|текст)$/i.test(x);})[0];if(t){t.click();return 'ok';}return 'none';})()
''');
    await Future<void>.delayed(const Duration(seconds: 3));
    final text = await b.read();
    b.hide();
    return text;
  }
}
