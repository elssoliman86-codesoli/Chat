import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_chat/ui/rich_media.dart';

void main() {
  test('youtubeId and videoThumbnail', () {
    expect(youtubeId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    expect(youtubeId('https://youtu.be/dQw4w9WgXcQ?t=5'), 'dQw4w9WgXcQ');
    expect(youtubeId('https://m.youtube.com/shorts/abcDEF12345'), 'abcDEF12345');
    expect(youtubeId('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
    expect(videoThumbnail('https://youtu.be/dQw4w9WgXcQ'), 'https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg');
    expect(videoThumbnail('https://example.com'), isNull);
    expect(isVideoLink('https://vimeo.com/12345'), isTrue);
    expect(isVideoLink('https://example.com/a'), isFalse);
  });

  test('two or more images in a row become a gallery block', () {
    const text = 'Here:\n![a](https://x.com/1.jpg)\n![b](https://x.com/2.jpg)\n\n![c](https://x.com/3.jpg)\nDone';
    final out = groupMedia(text);
    expect(out, contains('```gallery'));
    expect(out, contains('https://x.com/1.jpg\ta'));
    expect(out, contains('https://x.com/3.jpg\tc'));
    expect(out, contains('Done'));
    expect(out, isNot(contains('![a]')));
  });

  test('several images on one line also group; a single image is untouched', () {
    expect(groupMedia('![a](https://x.com/1.jpg) ![b](https://x.com/2.jpg)'), contains('```gallery'));
    const single = 'Look\n![a](https://x.com/1.jpg)\nbye';
    expect(groupMedia(single), single);
  });

  test('images inside a code fence or a sentence are left alone', () {
    const fenced = '```md\n![a](https://x.com/1.jpg)\n![b](https://x.com/2.jpg)\n```';
    expect(groupMedia(fenced), fenced);
    const inline = 'text ![a](https://x.com/1.jpg) more text\n![b](https://x.com/2.jpg) tail';
    expect(groupMedia(inline), inline);
  });

  test('a video link on its own line becomes a card; other links stay', () {
    final out = groupMedia('Watch:\nhttps://youtu.be/dQw4w9WgXcQ\n[Tutorial](https://www.youtube.com/watch?v=abcDEF12345)\nbye');
    expect(out, contains('```cards'));
    expect(out, contains('https://youtu.be/dQw4w9WgXcQ'));
    expect(out, contains('https://www.youtube.com/watch?v=abcDEF12345\tTutorial'));
    const plain = 'see https://example.com/page\nhttps://example.com/other';
    expect(groupMedia(plain), plain);
  });

  test('parseMedia reads tab, markdown and bare lines', () {
    final items = parseMedia('https://x.com/1.jpg\tOne\nhttps://x.com/2.jpg\n![Three](https://x.com/3.jpg)\nnot a url');
    expect(items.map((i) => i.url), ['https://x.com/1.jpg', 'https://x.com/2.jpg', 'https://x.com/3.jpg']);
    expect(items.map((i) => i.title), ['One', '', 'Three']);
  });

  testWidgets('ImageCarousel shows a page view and LinkCards show host', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          ImageCarousel(items: const [MediaItem('https://x.com/1.jpg', 'One'), MediaItem('https://x.com/2.jpg', 'Two')]),
          LinkCards(items: const [MediaItem('https://example.com/v', 'A video')], onOpen: (_) {}),
        ]),
      ),
    ));
    expect(find.byType(PageView), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('A video'), findsOneWidget);
  });
}
