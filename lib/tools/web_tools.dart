import 'dart:convert';

import 'package:http/http.dart' as http;

/// Web search and page reading for the assistant. No API key needed.
class WebTools {
  static const String _ua = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  static Future<String> _get(String url, {int maxChars = 700000}) async {
    final res = await http.get(Uri.parse(url), headers: <String, String>{
      'User-Agent': _ua,
      'Accept-Language': 'en-US,en;q=0.9,ar;q=0.8,ru;q=0.7',
      'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.5',
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    return text.length > maxChars ? text.substring(0, maxChars) : text;
  }

  static String decodeEntities(String input) => input
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#160;', ' ');

  static String htmlToText(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<(script|style|noscript|svg|head)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), ' ');
    s = s.replaceAll(RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = decodeEntities(s);
    s = s.replaceAll(RegExp(r'[ \t ]+'), ' ');
    s = s.replaceAll(RegExp(r'\s*\n\s*'), '\n');
    return s.trim();
  }

  static String _clean(String fragment) =>
      decodeEntities(fragment.replaceAll(RegExp(r'<[^>]+>'), '')).replaceAll(RegExp(r'\s+'), ' ').trim();

  static Future<List<Map<String, String>>> _duckduckgo(String query) async {
    final html = await _get('https://html.duckduckgo.com/html/?q=${Uri.encodeQueryComponent(query)}');
    final link = RegExp(r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>', caseSensitive: false, dotAll: true);
    final snippet = RegExp(r'class="result__snippet"[^>]*>(.*?)</a>', caseSensitive: false, dotAll: true);
    final links = link.allMatches(html).toList();
    final snippets = snippet.allMatches(html).toList();
    final hits = <Map<String, String>>[];
    for (var i = 0; i < links.length; i++) {
      var href = decodeEntities(links[i].group(1) ?? '');
      final uddg = RegExp(r'[?&]uddg=([^&]+)').firstMatch(href)?.group(1);
      if (uddg != null) href = Uri.decodeComponent(uddg);
      if (href.startsWith('//')) href = 'https:$href';
      if (!href.startsWith('http')) continue;
      hits.add(<String, String>{
        'title': _clean(links[i].group(2) ?? ''),
        'url': href,
        'snippet': i < snippets.length ? _clean(snippets[i].group(1) ?? '') : '',
      });
    }
    return hits;
  }

  static Future<List<Map<String, String>>> _bing(String query) async {
    final html = await _get('https://www.bing.com/search?q=${Uri.encodeQueryComponent(query)}');
    final hits = <Map<String, String>>[];
    final block = RegExp(r'<li class="b_algo".*?</li>', caseSensitive: false, dotAll: true);
    for (final m in block.allMatches(html)) {
      final b = m.group(0) ?? '';
      final a = RegExp(r'<h2[^>]*><a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', caseSensitive: false, dotAll: true).firstMatch(b);
      if (a == null) continue;
      final snip = RegExp(r'<p[^>]*>(.*?)</p>', caseSensitive: false, dotAll: true).firstMatch(b)?.group(1) ?? '';
      final href = decodeEntities(a.group(1) ?? '');
      if (href.startsWith('http')) {
        hits.add(<String, String>{'title': _clean(a.group(2) ?? ''), 'url': href, 'snippet': _clean(snip)});
      }
    }
    return hits;
  }

  /// Search hits as title, url and snippet. Empty when every engine failed.
  static Future<List<Map<String, String>>> results(String query) async {
    var hits = <Map<String, String>>[];
    try {
      hits = await _duckduckgo(query);
    } catch (_) {}
    if (hits.isEmpty) {
      try {
        hits = await _bing(query);
      } catch (_) {}
    }
    return hits;
  }

  /// Numbered results as plain text for the model.
  static Future<String> search(String query, {int max = 7}) async {
    var hits = <Map<String, String>>[];
    var failure = '';
    try {
      hits = await _duckduckgo(query);
    } catch (e) {
      failure = e.toString();
    }
    if (hits.isEmpty) {
      try {
        hits = await _bing(query);
      } catch (e) {
        failure = e.toString();
      }
    }
    if (hits.isEmpty) return 'No results (search failed: $failure)';
    final buffer = StringBuffer();
    var n = 0;
    for (final h in hits.take(max)) {
      n++;
      final snip = h['snippet'] ?? '';
      buffer.writeln('$n. ${h['title']}\n   ${h['url']}\n   ${snip.length > 220 ? snip.substring(0, 220) : snip}');
    }
    return buffer.toString().trim();
  }

  /// Readable text of a page.
  static Future<String> fetchText(String url, {int maxChars = 6000}) async {
    try {
      final raw = await _get(url);
      final t = raw.trimLeft();
      final text = (t.startsWith('{') || t.startsWith('[')) ? raw : htmlToText(raw);
      if (text.trim().isEmpty) return 'The page had no readable text.';
      return text.length > maxChars ? text.substring(0, maxChars) : text;
    } catch (e) {
      return 'Could not open the page: $e';
    }
  }
}
