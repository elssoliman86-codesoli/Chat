import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/models.dart';
import 'browser_service.dart';
import 'web_chat_driver.dart';

/// Which chat website a message goes to.
enum ChatSlot { primary, secondary, image }

/// The chat site could not be used; [message] says why in plain words (and what to do about it).
class ChatBridgeError implements Exception {
  const ChatBridgeError(this.message, {this.needsPerson = false});
  final String message;

  /// A sign-in or human check the person has to do once in the browser.
  final bool needsPerson;
  @override
  String toString() => message;
}

/// What one look at the chat page says.
class ChatState {
  const ChatState({this.generating = false, this.count = 0, this.len = 0, this.hash = 0, this.inputLen = -1});

  final bool generating;
  final int count;
  final int len;
  final int hash;
  final int inputLen;

  static ChatState parse(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return ChatState(
        generating: j['gen'] == true,
        count: (j['count'] as num?)?.toInt() ?? 0,
        len: (j['len'] as num?)?.toInt() ?? 0,
        hash: (j['h'] as num?)?.toInt() ?? 0,
        inputLen: (j['inLen'] as num?)?.toInt() ?? -1,
      );
    } catch (_) {
      return const ChatState();
    }
  }
}

/// Decides when an answer is complete: it has started, the site no longer shows a stop button, and the text has not
/// changed for [quiet]. Kept apart from the web view so it can be tested.
class AnswerWatch {
  AnswerWatch({required this.base, this.quiet = const Duration(milliseconds: 3000), this.startTimeout = const Duration(seconds: 25)});

  final ChatState base;
  final Duration quiet;
  final Duration startTimeout;

  bool started = false;
  int _hash = 0;
  Duration _stableSince = Duration.zero;

  /// Feed one look at the page with the time since sending. Returns 'wait', 'done' or 'never-started'.
  String feed(ChatState s, Duration now) {
    if (!started) {
      if (s.generating || s.count > base.count || s.hash != base.hash) {
        started = true;
        _hash = s.hash;
        _stableSince = now;
      } else if (now > startTimeout) {
        return 'never-started';
      }
      return 'wait';
    }
    if (s.generating || s.hash != _hash) {
      _hash = s.hash;
      _stableSince = now;
      return 'wait';
    }
    // Nothing visible yet (the model is still thinking): wait longer before calling it finished.
    // With no recognisable answer box the page text is all there is to go by: be more patient.
    final needed = s.len == 0 ? quiet * 3 : (s.count == 0 ? quiet * 2 : quiet);
    return now - _stableSince >= needed ? 'done' : 'wait';
  }
}

class _Slot {
  _Slot(this.slot);

  final ChatSlot slot;
  WebViewController? controller;
  final ValueNotifier<bool> needed = ValueNotifier<bool>(false);
  final GlobalKey viewKey = GlobalKey();
  Completer<void>? loaded;
  Future<void> queue = Future<void>.value();
  String sessionKey = '';
  String openUrl = '';
}

/// Uses chat websites in the background, like a person would: a hidden web view per link, one message at a time.
/// Sign-in is shared with the built-in browser (same cookies), so signing in there once is enough.
class WebChatBridge {
  WebChatBridge._();
  static final WebChatBridge instance = WebChatBridge._();

  final Map<ChatSlot, _Slot> _slots = <ChatSlot, _Slot>{for (final s in ChatSlot.values) s: _Slot(s)};

  /// Rebuilds the hidden views when a slot starts being used.
  final ValueNotifier<int> mounts = ValueNotifier<int>(0);

  WebViewController? controllerOf(ChatSlot s) => _slots[s]!.controller;
  Key keyOf(ChatSlot s) => _slots[s]!.viewKey;

  WebViewController _controller(_Slot s) {
    final existing = s.controller;
    if (existing != null) return existing;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(BrowserService.instance.modeUserAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (u) {
          final l = s.loaded;
          if (l != null && !l.isCompleted) l.complete();
          unawaited(BrowserService.instance.prepareNative());
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) {
            final l = s.loaded;
            if (l != null && !l.isCompleted) l.completeError(ChatBridgeError('The page did not load (${e.description}).'));
          }
        },
      ));
    s.controller = c;
    s.needed.value = true;
    mounts.value++;
    return c;
  }

  Future<String> _js(WebViewController c, String code) async {
    final raw = await c.runJavaScriptReturningResult(code);
    var s = raw.toString();
    if (s.startsWith('"')) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {}
    }
    return s;
  }

  Future<void> _install(WebViewController c) => c.runJavaScript(webChatDriverJs);

  /// Sends [message] to the chat of [slot] and returns the answer when it is complete.
  /// [sessionKey] ties the messages of one conversation to one chat thread: the same key keeps talking in the same
  /// thread, another key (or [newThread]) opens a fresh one.
  Future<String> ask(
    ChatSlot slot,
    String url,
    String message, {
    String sessionKey = '',
    bool newThread = false,
    Attachment? image,
    Duration timeout = const Duration(minutes: 6),
    bool Function()? cancelled,
  }) {
    final s = _slots[slot]!;
    final run = s.queue.then((_) => _askNow(s, url, message, sessionKey, newThread, image, timeout, cancelled ?? () => false));
    s.queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _open(_Slot s, String url) async {
    final c = _controller(s);
    // A frame for the hidden view to be attached before the page starts.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    s.loaded = Completer<void>();
    await c.loadRequest(Uri.parse(url));
    try {
      await s.loaded!.future.timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw const ChatBridgeError('The chat page took too long to load.');
    }
    s.openUrl = url;
  }

  Future<void> _waitForInput(_Slot s, bool Function() cancelled) async {
    final c = s.controller!;
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 30)) {
      if (cancelled()) throw const ChatBridgeError('Stopped.');
      String wall = '';
      try {
        await _install(c);
        if ((await _js(c, 'window.__oc.hasInput()')) == 'true') return;
        wall = await _js(c, 'window.__oc.wall()');
      } catch (_) {
        // The page is still navigating; look again.
      }
      if (wall == 'human' && clock.elapsed > const Duration(seconds: 8)) {
        throw const ChatBridgeError(
            'The chat site shows a "verify you are human" check. Open it in the built-in browser once, pass the check, then try again.',
            needsPerson: true);
      }
      if (wall == 'login' && clock.elapsed > const Duration(seconds: 6)) {
        throw const ChatBridgeError(
            'The chat site wants you to sign in. Open it in the built-in browser (Settings → Plugins → Web chat team → Open), sign in once, then try again.',
            needsPerson: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    throw const ChatBridgeError('Could not find the message box on the chat page. Open the link in the built-in browser to check what it shows.');
  }

  Future<String> _askNow(_Slot s, String url, String message, String sessionKey, bool newThread, Attachment? image, Duration timeout,
      bool Function() cancelled) async {
    if (url.trim().isEmpty) throw const ChatBridgeError('No link is set for this chat.');
    var target = url.trim();
    if (!target.startsWith('http')) target = 'https://$target';
    final fresh = newThread || image != null || s.controller == null || s.sessionKey != sessionKey || s.openUrl != target;
    if (fresh) {
      await _open(s, target);
      s.sessionKey = sessionKey;
    }
    final c = s.controller!;
    await _waitForInput(s, cancelled);

    if (image != null) await _attach(c, image, cancelled);

    final baseRaw = await _js(c, 'window.__oc.state()');
    final base = ChatState.parse(baseRaw);
    final baseLen = int.tryParse(await _js(c, 'window.__oc.bodyLen()')) ?? 0;

    // Type it (checking it really landed in the box), then press send.
    final want = message.replaceAll(RegExp(r'\s+'), '').length;
    for (var attempt = 0; attempt < 3; attempt++) {
      await _js(c, 'window.__oc.put(${jsonEncode(message)})');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final have = int.tryParse(await _js(c, 'window.__oc.inputLen()')) ?? -1;
      if (have >= want * 0.8) break;
      if (attempt == 2) throw const ChatBridgeError('The message did not get typed into the chat box.');
    }
    var sent = false;
    for (final mode in const <String>['button', 'enter', 'guess']) {
      // A send button is often disabled for a moment after typing: try the named button a few times first.
      for (var i = 0; i < (mode == 'button' ? 4 : 1); i++) {
        if (cancelled()) throw const ChatBridgeError('Stopped.');
        final how = await _js(c, 'window.__oc.send(${jsonEncode(mode)})');
        if (how == 'none' || how == 'no-input') {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        // Did it go? The box empties or the site starts answering.
        for (var k = 0; k < 8; k++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final st = ChatState.parse(await _js(c, 'window.__oc.state()'));
          if (st.generating || st.count > base.count || st.hash != base.hash || (st.inputLen >= 0 && st.inputLen < want * 0.2)) {
            sent = true;
            break;
          }
        }
        if (sent) break;
      }
      if (sent) break;
    }
    if (!sent) throw const ChatBridgeError('Could not press send on the chat page.');

    final watch = AnswerWatch(base: base);
    final sentAt = Stopwatch()..start();
    while (true) {
      if (cancelled()) throw const ChatBridgeError('Stopped.');
      if (sentAt.elapsed > timeout) throw ChatBridgeError('The chat did not finish answering in ${timeout.inMinutes} minutes.');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final st = ChatState.parse(await _js(c, 'window.__oc.state()'));
      final r = watch.feed(st, sentAt.elapsed);
      if (r == 'done') break;
      if (r == 'never-started') throw const ChatBridgeError('The chat did not answer (nothing happened after sending).');
    }
    var text = await _js(c, 'window.__oc.last()');
    if (text.trim().isEmpty) {
      text = await _js(c, 'window.__oc.bodyTail(${jsonEncode(message)}, $baseLen)');
    }
    text = text.trim();
    if (text.isEmpty) throw const ChatBridgeError('The chat gave an empty answer.');
    return text;
  }

  // ------------------------------------------------------------------ images

  /// The image bytes to upload: as stored when small, shrunk to 1600 px when large (chat sites resize anyway).
  static Future<(Uint8List, String, String)> imageBytes(Attachment a) async {
    var bytes = await File(a.path).readAsBytes();
    var mime = a.mime.isEmpty ? 'image/png' : a.mime;
    var name = a.name.isEmpty ? 'image.png' : a.name;
    if (bytes.length > 1500000) {
      try {
        final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1600);
        final frame = await codec.getNextFrame();
        final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        if (data != null && data.lengthInBytes < bytes.length) {
          bytes = data.buffer.asUint8List();
          mime = 'image/png';
          name = '${name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name}.png';
        }
      } catch (_) {}
    }
    return (bytes, mime, name);
  }

  Future<void> _attach(WebViewController c, Attachment image, bool Function() cancelled) async {
    final (bytes, mime, name) = await imageBytes(image);
    final b64 = base64Encode(bytes);
    await _js(c, 'window.__oc.upStart(${jsonEncode(name)}, ${jsonEncode(mime)})');
    const chunk = 180000;
    for (var i = 0; i < b64.length; i += chunk) {
      final end = i + chunk > b64.length ? b64.length : i + chunk;
      await _js(c, 'window.__oc.upPart("${b64.substring(i, end)}")');
    }
    final how = await _js(c, 'window.__oc.upFinish()');
    if (how == 'none' || how == 'no-upload') {
      throw const ChatBridgeError('This chat page has no place to attach an image.');
    }
    // Wait for the preview of the picture to show up (the upload finishing) before sending the question.
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 12)) {
      if (cancelled()) throw const ChatBridgeError('Stopped.');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final n = int.tryParse(await _js(c, 'window.__oc.previews(${jsonEncode(name)})')) ?? 0;
      if (n > 0 && clock.elapsed > const Duration(seconds: 1)) break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  static const String imagePrompt = 'Copy ALL the text that appears in this image exactly as written, in its original language and direction '
      '(Arabic, English, Russian and others), keeping line breaks. If there is no text, write "No text". '
      'Then add a line starting with "Description:" that says in one or two sentences what the image shows. '
      'Reply with that only.';

  /// Reads an image with the image chat link: uploads it, asks for its text and returns the answer.
  Future<String> readImage(String url, Attachment image, {bool Function()? cancelled}) =>
      ask(ChatSlot.image, url, imagePrompt, image: image, cancelled: cancelled, timeout: const Duration(minutes: 3));
}

/// Mounts the hidden web views of the chat links. They are phone-sized and nearly transparent (like the browser's
/// hidden mode) so the sites lay out normally and keep running, without covering the chat or taking touches.
/// Put this inside the same Stack as the chat, alongside DockLayer.
class WebChatMount extends StatelessWidget {
  const WebChatMount({super.key});

  @override
  Widget build(BuildContext context) {
    final b = WebChatBridge.instance;
    return ValueListenableBuilder<int>(
      valueListenable: b.mounts,
      builder: (context, _, __) {
        final children = <Widget>[];
        for (final slot in ChatSlot.values) {
          final c = b.controllerOf(slot);
          if (c == null) continue;
          children.add(Positioned(
            left: 0,
            top: 0,
            width: 390,
            height: 780,
            child: ExcludeSemantics(
              child: IgnorePointer(child: Opacity(opacity: 0.01, child: WebViewWidget(key: b.keyOf(slot), controller: c))),
            ),
          ));
        }
        if (children.isEmpty) return const SizedBox.shrink();
        return Stack(children: children);
      },
    );
  }
}
