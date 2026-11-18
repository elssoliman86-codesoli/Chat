import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'theme.dart';

/// One picture or video link shown inside a reply.
class MediaItem {
  const MediaItem(this.url, this.title);

  final String url;
  final String title;
}

/// The YouTube video id in a link, or null when it is not a YouTube video link.
String? youtubeId(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasAuthority) return null;
  var host = u.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  if (host.startsWith('m.')) host = host.substring(2);
  String? id;
  if (host == 'youtu.be') {
    id = u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
  } else if (host == 'youtube.com' || host == 'music.youtube.com' || host == 'youtube-nocookie.com') {
    if (u.path == '/watch') {
      id = u.queryParameters['v'];
    } else if (u.pathSegments.length >= 2 && const {'shorts', 'embed', 'live', 'v'}.contains(u.pathSegments.first)) {
      id = u.pathSegments[1];
    }
  }
  if (id != null && RegExp(r'^[A-Za-z0-9_-]{6,15}$').hasMatch(id)) return id;
  return null;
}

/// A preview image for a video link (YouTube today), or null.
String? videoThumbnail(String url) {
  final id = youtubeId(url);
  return id == null ? null : 'https://img.youtube.com/vi/$id/hqdefault.jpg';
}

/// Whether a link points at a video the chat can show a thumbnail card for.
bool isVideoLink(String url) {
  if (youtubeId(url) != null) return true;
  final u = Uri.tryParse(url.trim());
  if (u == null) return false;
  final host = u.host.toLowerCase();
  return host.endsWith('vimeo.com') || host.endsWith('dailymotion.com') || host.endsWith('tiktok.com');
}

String hostOf(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h.startsWith('www.') ? h.substring(4) : h;
}

final RegExp _imageRef = RegExp(r'!\[([^\]]*)\]\(\s*<?(https?://[^)\s>]+)>?(?:\s+"[^"]*")?\s*\)');
final RegExp _imageOnlyLine = RegExp(r'^\s*(?:!\[[^\]]*\]\([^)]*\)\s*)+$');
final RegExp _linkOnlyLine = RegExp(r'^\s*(?:[-*]\s+)?(?:\[([^\]]+)\]\((https?://[^)\s]+)\)|(https?://\S+))\s*$');

/// Rewrites a reply so that runs of two or more pictures, and lines holding just a video link,
/// become ```gallery and ```cards blocks that the chat draws as a swipeable slideshow and as
/// thumbnail cards. Everything else, and anything inside a code fence, is left untouched.
String groupMedia(String text) {
  if (!text.contains('![') && !text.contains('http')) return text;
  final lines = text.split('\n');
  final out = <String>[];
  var inFence = false;
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      out.add(line);
      i++;
      continue;
    }
    if (inFence) {
      out.add(line);
      i++;
      continue;
    }
    if (_imageOnlyLine.hasMatch(line)) {
      final items = <String>[];
      var j = i;
      var last = i;
      while (j < lines.length) {
        if (lines[j].trim().isEmpty) {
          j++;
          continue;
        }
        if (!_imageOnlyLine.hasMatch(lines[j])) break;
        for (final m in _imageRef.allMatches(lines[j])) {
          items.add('${m.group(2)}\t${(m.group(1) ?? '').replaceAll('\t', ' ')}');
        }
        last = j;
        j++;
      }
      if (items.length >= 2) {
        if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
        out
          ..add('```gallery')
          ..addAll(items)
          ..add('```')
          ..add('');
        i = last + 1;
        continue;
      }
      out.add(line);
      i++;
      continue;
    }
    final link = _linkOnlyLine.firstMatch(line);
    if (link != null) {
      final url = link.group(2) ?? link.group(3) ?? '';
      if (isVideoLink(url)) {
        final items = <String>[];
        var j = i;
        var last = i;
        while (j < lines.length) {
          if (lines[j].trim().isEmpty) {
            j++;
            continue;
          }
          final m = _linkOnlyLine.firstMatch(lines[j]);
          final u = m == null ? '' : (m.group(2) ?? m.group(3) ?? '');
          if (m == null || !isVideoLink(u)) break;
          items.add('$u\t${(m.group(1) ?? '').replaceAll('\t', ' ')}');
          last = j;
          j++;
        }
        if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
        out
          ..add('```cards')
          ..addAll(items)
          ..add('```')
          ..add('');
        i = last + 1;
        continue;
      }
    }
    out.add(line);
    i++;
  }
  return out.join('\n');
}

/// Parses the body of a ```gallery or ```cards block: one `url<TAB>title` (or just a url) per line.
List<MediaItem> parseMedia(String body) {
  final items = <MediaItem>[];
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final tab = line.indexOf('\t');
    var url = tab < 0 ? line : line.substring(0, tab).trim();
    var title = tab < 0 ? '' : line.substring(tab + 1).trim();
    final md = RegExp(r'^!?\[([^\]]*)\]\((https?://[^)\s]+)').firstMatch(line);
    if (md != null) {
      title = md.group(1) ?? '';
      url = md.group(2) ?? '';
    }
    if (url.startsWith('http')) items.add(MediaItem(url, title));
  }
  return items;
}

Widget _placeholder(BuildContext context, {IconData icon = CupertinoIcons.photo, String? label, bool loading = false}) {
  final pal = paletteOf(context);
  return Container(
    color: pal.field,
    alignment: Alignment.center,
    child: loading
        ? const SizedBox(width: 22, height: 22, child: CupertinoActivityIndicator())
        : Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 26, color: pal.secondary),
            if (label != null && label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: pal.secondary)),
              ),
          ]),
  );
}

Widget networkPicture(BuildContext context, String url, {BoxFit fit = BoxFit.cover, String? label}) {
  return Image.network(
    url,
    fit: fit,
    loadingBuilder: (context, child, progress) => progress == null ? child : _placeholder(context, loading: true),
    errorBuilder: (context, error, stack) => _placeholder(context, icon: CupertinoIcons.exclamationmark_triangle, label: label?.isNotEmpty == true ? label : 'Image could not load'),
  );
}

/// Pictures side by side as slides that swipe left and right; tapping one opens it full screen.
class ImageCarousel extends StatefulWidget {
  const ImageCarousel({super.key, required this.items});

  final List<MediaItem> items;

  @override
  State<ImageCarousel> createState() => _ImageCarouselState();
}

class _ImageCarouselState extends State<ImageCarousel> {
  final PageController _controller = PageController(viewportFraction: 0.8);
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open(int index) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      pageBuilder: (context, a, b) => _FullScreenGallery(items: widget.items, start: index),
      transitionsBuilder: (context, a, b, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final items = widget.items;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 210,
          child: PageView.builder(
            controller: _controller,
            itemCount: items.length,
            padEnds: false,
            onPageChanged: (p) => setState(() => _page = p),
            itemBuilder: (context, i) {
              final item = items[i];
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => _open(i),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Stack(fit: StackFit.expand, children: [
                      networkPicture(context, item.url, label: item.title),
                      if (item.title.isNotEmpty)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xB3000000)]),
                            ),
                            child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                          ),
                        ),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
        if (items.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < items.length && i < 12; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(color: i == _page ? pal.accent : pal.separator, borderRadius: BorderRadius.circular(3)),
                ),
              if (items.length > 12) Text('  ${_page + 1}/${items.length}', style: TextStyle(fontSize: 11, color: pal.secondary)),
            ]),
          ),
      ]),
    );
  }
}

class _FullScreenGallery extends StatefulWidget {
  const _FullScreenGallery({required this.items, required this.start});

  final List<MediaItem> items;
  final int start;

  @override
  State<_FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<_FullScreenGallery> {
  late final PageController _controller = PageController(initialPage: widget.start);
  late int _page = widget.start;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_page];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        PageView.builder(
          controller: _controller,
          itemCount: widget.items.length,
          onPageChanged: (p) => setState(() => _page = p),
          itemBuilder: (context, i) => GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(child: networkPicture(context, widget.items[i].url, fit: BoxFit.contain, label: widget.items[i].title)),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: IconButton(icon: const Icon(CupertinoIcons.xmark_circle_fill, color: Colors.white, size: 30), onPressed: () => Navigator.of(context).pop()),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                '${_page + 1} / ${widget.items.length}${item.title.isEmpty ? '' : '\n${item.title}'}',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

final Map<String, String> _titleCache = <String, String>{};

/// The title of a YouTube video from its public oEmbed endpoint; '' when it cannot be had.
Future<String> videoTitle(String url) async {
  final cached = _titleCache[url];
  if (cached != null) return cached;
  var title = '';
  if (youtubeId(url) != null) {
    try {
      final res = await http
          .get(Uri.parse('https://www.youtube.com/oembed?format=json&url=${Uri.encodeQueryComponent(url)}'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        if (j is Map && j['title'] is String) title = j['title'] as String;
      }
    } catch (_) {}
  }
  _titleCache[url] = title;
  return title;
}

/// Video links as cards with a thumbnail, the title and the site; tapping one opens the link.
class LinkCards extends StatelessWidget {
  const LinkCards({super.key, required this.items, required this.onOpen});

  final List<MediaItem> items;
  final void Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final item in items) _VideoCard(item: item, onOpen: onOpen),
      ]),
    );
  }
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({required this.item, required this.onOpen});

  final MediaItem item;
  final void Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    final pal = paletteOf(context);
    final thumb = videoThumbnail(item.url);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: pal.cell,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(item.url),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(fit: StackFit.expand, children: [
                if (thumb != null)
                  networkPicture(context, thumb, label: item.title)
                else
                  _placeholder(context, icon: CupertinoIcons.play_rectangle),
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(color: Color(0xB3000000), shape: BoxShape.circle),
                    child: const Icon(CupertinoIcons.play_fill, color: Colors.white, size: 26),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: FutureBuilder<String>(
                future: item.title.isNotEmpty ? Future<String>.value(item.title) : videoTitle(item.url),
                builder: (context, snap) {
                  final title = (snap.data ?? '').isNotEmpty ? snap.data! : item.title;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (title.isNotEmpty) Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(hostOf(item.url), style: TextStyle(fontSize: 12, color: pal.secondary)),
                  ]);
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
