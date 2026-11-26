import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/core/models.dart';
import 'package:omni_chat/tools/registry.dart';
import 'package:omni_chat/tools/web_chat_bridge.dart';
import 'package:omni_chat/tools/web_chat_driver.dart';

ChatState look({bool gen = false, int count = 0, int len = 0, int hash = 0, int inLen = 0}) =>
    ChatState(generating: gen, count: count, len: len, hash: hash, inputLen: inLen);

void main() {
  group('AnswerWatch', () {
    Duration s(int ms) => Duration(milliseconds: ms);

    test('is done only after the answer started, stopped changing and the stop button is gone', () {
      final w = AnswerWatch(base: look(count: 1, len: 50, hash: 7));
      expect(w.feed(look(count: 1, len: 50, hash: 7), s(500)), 'wait'); // nothing yet
      expect(w.feed(look(gen: true, count: 2, len: 5, hash: 8), s(1000)), 'wait'); // started, streaming
      expect(w.feed(look(gen: true, count: 2, len: 90, hash: 9), s(2000)), 'wait');
      expect(w.feed(look(count: 2, len: 90, hash: 9), s(3000)), 'wait'); // stop button gone, but not quiet long enough
      expect(w.feed(look(count: 2, len: 90, hash: 9), s(4900)), 'wait');
      expect(w.feed(look(count: 2, len: 90, hash: 9), s(5100)), 'done');
    });

    test('text that keeps changing is never finished, even without a stop button', () {
      final w = AnswerWatch(base: look());
      expect(w.feed(look(count: 1, len: 10, hash: 1), s(600)), 'wait');
      for (var i = 2; i < 10; i++) {
        expect(w.feed(look(count: 1, len: 10 * i, hash: i), s(600 * i)), 'wait');
      }
    });

    test('a site that never starts answering is reported', () {
      final w = AnswerWatch(base: look(count: 3, len: 10, hash: 4), startTimeout: s(5000));
      expect(w.feed(look(count: 3, len: 10, hash: 4), s(2000)), 'wait');
      expect(w.feed(look(count: 3, len: 10, hash: 4), s(5600)), 'never-started');
    });

    test('an empty answer (the model is still thinking) gets more patience', () {
      final w = AnswerWatch(base: look());
      expect(w.feed(look(gen: true, count: 1, len: 0, hash: 1), s(500)), 'wait');
      expect(w.feed(look(count: 1, len: 0, hash: 1), s(4000)), 'wait');
      expect(w.feed(look(count: 1, len: 0, hash: 1), s(10000)), 'done');
    });
  });

  test('the state reported by the page is parsed, and garbage gives an empty state', () {
    final parsed = ChatState.parse('{"gen":true,"count":2,"len":120,"h":-55,"inLen":0}');
    expect(parsed.generating, isTrue);
    expect(parsed.count, 2);
    expect(parsed.hash, -55);
    expect(ChatState.parse('not json').count, 0);
  });

  test('the driver script is balanced and defines every call the bridge makes', () {
    expect('{'.allMatches(webChatDriverJs).length, '}'.allMatches(webChatDriverJs).length);
    expect('('.allMatches(webChatDriverJs).length, ')'.allMatches(webChatDriverJs).length);
    for (final fn in ['hasInput', 'info', 'wall', 'put', 'inputLen', 'send', 'state', 'last', 'full', 'bodyLen', 'bodyTail', 'upStart', 'upPart', 'upFinish', 'previews']) {
      expect(webChatDriverJs, contains('$fn:'), reason: fn);
    }
  });

  test('a pasted sign-in link becomes the site start page', () {
    expect(WebChatBridge.chatHome('https://chat.deepseek.com/sign_in'), 'https://chat.deepseek.com/');
    expect(WebChatBridge.chatHome('chatgpt.com/auth/login'), 'https://chatgpt.com/');
    expect(WebChatBridge.chatHome('https://claude.ai/login?next=/new'), 'https://claude.ai/');
    expect(WebChatBridge.chatHome('https://claude.ai/new'), 'https://claude.ai/new');
    expect(WebChatBridge.chatHome(' https://gemini.google.com/app '), 'https://gemini.google.com/app');
  });

  group('hand-over to a new thread', () {
    test('the new thread starts with the summary and then the real message', () {
      final m = WebChatBridge.handoffMessage('  Goal: build X. Done: files a, b.  ', 'Now add login');
      expect(m, contains('continuation of an earlier chat'));
      expect(m, contains('Goal: build X. Done: files a, b.'));
      expect(m.indexOf('Goal: build X'), lessThan(m.indexOf('Now add login')));
    });

    test('when the chat cannot summarise itself a digest of the last exchanges is used', () {
      final ex = <(String, String)>[for (var i = 1; i <= 12; i++) ('question $i ${'x' * 2000}', 'answer $i')];
      final d = WebChatBridge.digest(ex);
      expect(d, contains('question 12'));
      expect(d, contains('answer 12'));
      expect(d, isNot(contains('question 1 ')));
      expect(d.length, lessThan(8 * 2200));
    });

    test('the summary request asks for the details a new chat needs', () {
      for (final w in ['decision', 'commands', 'next steps', 'summary only']) {
        expect(WebChatBridge.summaryRequest.toLowerCase(), contains(w));
      }
      expect(WebChatBridge.threadLimitChars, greaterThan(20000));
    });
  });

  group('turning it on', () {
    test('the helper chats need the chat switched on and a primary link', () {
      final c = Conversation(id: 'a');
      final settings = AppSettings();
      expect(ToolRegistry.webChatOn(c, settings), isFalse);
      c.assistChats = true;
      expect(ToolRegistry.webChatOn(c, settings), isFalse);
      settings.webChatPrimary = ' https://chatgpt.com ';
      expect(ToolRegistry.webChatOn(c, settings), isTrue);
      c.assistChats = false;
      expect(ToolRegistry.webChatOn(c, settings), isFalse);
    });

    test('links and the per-chat switch are saved', () {
      final saved = AppSettings()
        ..webChatPrimary = 'https://a'
        ..webChatSecondary = 'https://b'
        ..webChatImage = 'https://c'
        ..imageReader = 'web';
      final back = AppSettings.fromJson(saved.toJson());
      expect([back.webChatPrimary, back.webChatSecondary, back.webChatImage, back.imageReader], ['https://a', 'https://b', 'https://c', 'web']);
      final c = Conversation(id: 'x')..assistChats = true;
      expect(Conversation.fromJson(c.toJson()).assistChats, isTrue);
    });
  });
}
