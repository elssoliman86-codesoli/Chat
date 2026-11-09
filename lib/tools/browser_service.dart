import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const String browserUserAgent = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

enum DockMode { hidden, panel, full }

/// A question from the assistant that the person answers on a card above the browser panel.
class AskRequest {
  AskRequest(this.question);
  final String question;
  final Completer<String> done = Completer<String>();
}

/// The one browser of the app. The assistant drives it with browser_* tools while the person can watch
/// it in a panel, take over, or hide it. Sign-ins stay (cookies are kept), so Gmail and Canva stay logged in.
class BrowserService {
  BrowserService._();
  static final BrowserService instance = BrowserService._();

  /// The web view is only created once something needs it.
  final ValueNotifier<bool> needed = ValueNotifier<bool>(false);
  final ValueNotifier<DockMode> mode = ValueNotifier<DockMode>(DockMode.hidden);
  final ValueNotifier<String> url = ValueNotifier<String>('');
  final ValueNotifier<String> title = ValueNotifier<String>('');
  final ValueNotifier<int> progress = ValueNotifier<int>(0);
  final ValueNotifier<bool> canBack = ValueNotifier<bool>(false);
  final ValueNotifier<bool> canForward = ValueNotifier<bool>(false);

  /// Keeps the native view alive when the dock changes size.
  final GlobalKey viewKey = GlobalKey();

  final ValueNotifier<AskRequest?> ask = ValueNotifier<AskRequest?>(null);

  /// Brings the browser up and waits until the person answers, so they can sign in or solve a captcha in the page.
  Future<String> askInPanel(String question) async {
    final req = AskRequest(question);
    if (mode.value == DockMode.hidden) mode.value = DockMode.panel;
    ask.value = req;
    try {
      return await req.done.future;
    } finally {
      ask.value = null;
    }
  }

  /// When true the panel slides up while the assistant works. Default is the background.
  bool showWhileWorking = false;

  /// Console messages and failed requests of the current page, for checking a web project.
  final List<String> logs = <String>[];

  void _log(String line) {
    if (logs.length < 60) logs.add(line.length > 300 ? '${line.substring(0, 300)}…' : line);
  }

  void _revealIfWanted() {
    if (showWhileWorking && mode.value == DockMode.hidden) mode.value = DockMode.panel;
  }

  Completer<void>? _loaded;
  Future<void> _queue = Future<void>.value();
  String? _fileToUpload;

  late final WebViewController controller = _create();

  WebViewController _create() {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(browserUserAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => progress.value = p,
        onPageStarted: (u) => url.value = u,
        onPageFinished: (u) async {
          url.value = u;
          final l = _loaded;
          if (l != null && !l.isCompleted) l.complete();
          try {
            title.value = (await controller.getTitle()) ?? '';
            canBack.value = await controller.canGoBack();
            canForward.value = await controller.canGoForward();
          } catch (_) {}
        },
        onWebResourceError: (e) {
          final l = _loaded;
          if (e.isForMainFrame ?? true) {
            if (l != null && !l.isCompleted) l.completeError(Exception(e.description));
          } else {
            _log('Resource failed: ${e.description}');
          }
        },
        onHttpError: (e) {
          _log('HTTP ${e.response?.statusCode}: ${e.request?.uri}');
        },
      ))
      ..setOnConsoleMessage((m) {
        if (m.level == JavaScriptLogLevel.error || m.level == JavaScriptLogLevel.warning) {
          _log('console ${m.level.name}: ${m.message}');
        }
      });
    final platform = c.platform;
    if (platform is AndroidWebViewController) {
      // Lets the assistant hand a stored image to a page's "upload" button.
      platform.setOnShowFileSelector((params) async {
        final f = _fileToUpload;
        return f == null ? <String>[] : <String>[Uri.file(f).toString()];
      });
    }
    return c;
  }

  void show({String? address, bool full = false}) {
    needed.value = true;
    mode.value = full ? DockMode.full : DockMode.panel;
    if (address != null && address.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => controller.loadRequest(Uri.parse(address)));
    }
  }

  void hide() => mode.value = DockMode.hidden;

  Future<T> _serial<T>(Future<T> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _load(String address) async {
    needed.value = true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _loaded = Completer<void>();
    await controller.loadRequest(Uri.parse(address));
    await _loaded!.future.timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }

  /// Visible text of [address], loaded without showing the browser.
  Future<String> render(String address, {int maxChars = 9000}) => _serial(() async {
        await _load(address);
        return pageText(controller, maxChars);
      });

  // ------------------------------------------------------------------ agent actions

  static const String _snapshotJs = r'''
(function(){
 document.querySelectorAll('[data-oid]').forEach(function(e){e.removeAttribute('data-oid');});
 var els=[].slice.call(document.querySelectorAll('a[href],button,input,textarea,select,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=option],[onclick],summary,[contenteditable=true]'));
 var out=[];var n=0;
 function vis(e){var r=e.getBoundingClientRect();if(r.width<2||r.height<2)return false;var s=getComputedStyle(e);if(s.visibility==='hidden'||s.display==='none'||parseFloat(s.opacity)===0)return false;return r.bottom>0&&r.right>0&&r.top<innerHeight*2.5;}
 for(var i=0;i<els.length&&n<90;i++){var e=els[i];if(!vis(e))continue;e.setAttribute('data-oid',String(n));
  var t=(e.innerText||e.value||e.getAttribute('aria-label')||e.placeholder||e.title||'').trim().replace(/\s+/g,' ').slice(0,80);
  var tag=e.tagName.toLowerCase();var type=e.getAttribute('type')||'';var extra='';
  if(tag==='a'){extra=' -> '+(e.getAttribute('href')||'').slice(0,70);}
  if((tag==='input'||tag==='textarea')&&e.value&&type!=='password'){extra=' value="'+String(e.value).slice(0,40)+'"';}
  var r=e.getBoundingClientRect();var box=' @'+Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height);
  out.push('['+n+'] '+tag+(type?'('+type+')':'')+(t?' "'+t+'"':'')+extra+box);n++;}
 var text=(document.body?document.body.innerText:'').replace(/\n{3,}/g,'\n\n').slice(0,3500);
 return JSON.stringify({title:document.title,url:location.href,text:text,elements:out});
})()
''';

  Future<dynamic> _eval(String js) async {
    final raw = await controller.runJavaScriptReturningResult(js);
    var s = raw.toString();
    if (s.startsWith('"')) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {}
    }
    return s;
  }

  /// A text description of the page: address, visible text and numbered clickable elements.
  Future<String> snapshot() async {
    final raw = await _eval(_snapshotJs);
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      final b = StringBuffer();
      b.writeln('Page: ${j['title']}\n${j['url']}\n');
      b.writeln('Visible text:\n${j['text']}\n');
      b.writeln('Elements (use the number with browser_click / browser_type; "@x,y wxh" is its position and size on '
          'screen in pixels — use it to tell whether two elements overlap):');
      for (final e in (j['elements'] as List)) {
        b.writeln(e);
      }
      return b.toString();
    } catch (_) {
      return raw.toString();
    }
  }

  Future<String> open(String address) => _serial(() async {
        _revealIfWanted();
        var a = address.trim();
        if (!a.startsWith('http')) a = 'https://$a';
        await _load(a);
        return snapshot();
      });

  Future<String> read() => _serial(snapshot);

  Future<String> click(int id) => _serial(() async {
        _revealIfWanted();
        _loaded = Completer<void>();
        final r = await _eval('''
(function(id){var e=document.querySelector('[data-oid="'+id+'"]');if(!e)return 'Element $id not found. Read the page again.';
 e.scrollIntoView({block:'center'});if(e.focus)e.focus();
 ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window}));});
 return 'Clicked: '+((e.innerText||e.getAttribute('aria-label')||e.tagName)+'').slice(0,60);})($id)
''');
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        return '$r\n\n${await snapshot()}';
      });

  Future<String> type(int id, String text, bool submit) => _serial(() async {
        _revealIfWanted();
        final t = jsonEncode(text);
        final r = await _eval('''
(function(id,text,submit){var e=document.querySelector('[data-oid="'+id+'"]');if(!e)return 'Element '+id+' not found. Read the page again.';
 e.scrollIntoView({block:'center'});e.focus();
 if(e.isContentEditable){document.execCommand('selectAll');document.execCommand('insertText',false,text);}
 else{var proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;var d=Object.getOwnPropertyDescriptor(proto,'value');
  if(d&&d.set){d.set.call(e,text);}else{e.value=text;}
  e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));}
 if(submit){['keydown','keypress','keyup'].forEach(function(t){e.dispatchEvent(new KeyboardEvent(t,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));});
  var f=e.form;if(f){if(f.requestSubmit){f.requestSubmit();}else{f.submit();}}}
 return 'Typed into element '+id;})($id,$t,${submit ? 'true' : 'false'})
''');
        await Future<void>.delayed(Duration(milliseconds: submit ? 2200 : 500));
        return '$r\n\n${await snapshot()}';
      });

  /// Drags an element by (dx, dy) screen pixels — a real pointer-down, several pointer-moves, then
  /// pointer-up, not a single jump, since most drag-based UIs (design canvases, sliders, reorderable
  /// lists) only register movement that comes as a sequence of small steps. Note: because these are
  /// script-dispatched events (not real touches), a page that specifically checks event.isTrusted before
  /// accepting a drag will ignore this — that is a real limit of browser automation, not a bug here.
  Future<String> drag(int id, int dx, int dy) => _serial(() async {
        _revealIfWanted();
        final r = await _eval('''
(function(id,dx,dy){
 var e=document.querySelector('[data-oid="'+id+'"]');if(!e)return 'Element '+id+' not found. Read the page again.';
 e.scrollIntoView({block:'center'});
 var r=e.getBoundingClientRect();var x0=r.left+r.width/2,y0=r.top+r.height/2;var steps=12;
 function fire(type,x,y){
  var mouseType=type.replace('pointer','mouse');
  var opts={bubbles:true,cancelable:true,view:window,clientX:x,clientY:y,button:0,buttons:1};
  try{e.dispatchEvent(new PointerEvent(type,Object.assign({pointerId:1,pointerType:'mouse',isPrimary:true},opts)));}catch(err){}
  e.dispatchEvent(new MouseEvent(mouseType,opts));
 }
 fire('pointerdown',x0,y0);
 for(var i=1;i<=steps;i++){fire('pointermove',x0+dx*i/steps,y0+dy*i/steps);}
 fire('pointerup',x0+dx,y0+dy);
 return 'Dragged element '+id+' by ('+dx+', '+dy+') pixels.';
})($id,$dx,$dy)
''');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return '$r\n\n${await snapshot()}';
      });

  Future<String> scroll(bool down) => _serial(() async {
        await _eval('window.scrollBy(0, ${down ? '' : '-'}Math.round(innerHeight*0.8)); "ok"');
        await Future<void>.delayed(const Duration(milliseconds: 600));
        return snapshot();
      });

  Future<String> back() => _serial(() async {
        _loaded = Completer<void>();
        await controller.goBack();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        return snapshot();
      });

  static const String _checkJs = r'''
(function(){
 var w=innerWidth,out={};
 function nm(e){var c=(typeof e.className==='string'&&e.className)?'.'+e.className.trim().split(/\s+/)[0]:'';return e.tagName.toLowerCase()+(e.id?'#'+e.id:'')+c;}
 out.title=document.title;
 out.viewportMeta=!!document.querySelector('meta[name=viewport]');
 out.width=w;out.scrollWidth=document.documentElement.scrollWidth;out.scrollHeight=document.documentElement.scrollHeight;
 var over=[];var all=document.querySelectorAll('body *');
 for(var i=0;i<all.length&&over.length<8;i++){var r=all[i].getBoundingClientRect();if(r.width>0&&r.right>w+2){over.push(nm(all[i])+' right='+Math.round(r.right));}}
 out.overflowing=over;
 out.brokenImages=[].slice.call(document.images).filter(function(i){return i.complete&&i.naturalWidth===0;}).map(function(i){return i.getAttribute('src');}).slice(0,8);
 out.headings=[].slice.call(document.querySelectorAll('h1,h2,h3')).slice(0,14).map(function(h){return h.tagName+': '+(h.innerText||'').trim().slice(0,60);});
 out.counts={links:document.links.length,buttons:document.querySelectorAll('button').length,inputs:document.querySelectorAll('input,textarea,select').length,images:document.images.length,deadLinks:document.querySelectorAll('a[href="#"],a:not([href])').length};
 var small=0;for(var j=0;j<all.length;j++){var t=all[j];if(t.children.length===0&&(t.innerText||'').trim()){var fs=parseFloat(getComputedStyle(t).fontSize);if(fs<11)small++;}}
 out.tinyTextElements=small;
 var blocks=[];var kids=document.body?document.body.children:[];
 for(var k=0;k<kids.length&&blocks.length<14;k++){var b=kids[k];if(['SCRIPT','STYLE'].indexOf(b.tagName)>=0)continue;var rr=b.getBoundingClientRect();blocks.push(nm(b)+' h='+Math.round(rr.height)+' "'+(b.innerText||'').trim().replace(/\s+/g,' ').slice(0,50)+'"');}
 out.layout=blocks;
 var bg=getComputedStyle(document.body).backgroundColor,fg=getComputedStyle(document.body).color;
 out.bodyColors='text '+fg+' on '+bg;
 out.text=(document.body?document.body.innerText:'').replace(/\n{3,}/g,'\n\n').slice(0,1800);
 return JSON.stringify(out);
})()
''';

  /// Opens a page in the background and reports what a person would see and what is broken:
  /// text, structure, overflow, broken images and any script errors or failed requests.
  Future<String> check(String address, {int waitMs = 1200}) => _serial(() async {
        logs.clear();
        _revealIfWanted();
        await _load(address);
        await Future<void>.delayed(Duration(milliseconds: waitMs));
        final raw = await _eval(_checkJs);
        final b = StringBuffer();
        try {
          final j = jsonDecode(raw as String) as Map<String, dynamic>;
          b.writeln('Checked $address (viewport ${j['width']}px wide, like a phone)');
          b.writeln('Title: ${j['title']}');
          b.writeln('Viewport meta tag: ${j['viewportMeta'] == true ? 'yes' : 'MISSING (page will not be responsive)'}');
          final sw = j['scrollWidth'] as num? ?? 0;
          final w = j['width'] as num? ?? 0;
          b.writeln('Horizontal overflow: ${sw > w + 2 ? 'YES, content is ${sw}px wide in a ${w}px screen' : 'no'}');
          final over = (j['overflowing'] as List?) ?? <dynamic>[];
          if (over.isNotEmpty) b.writeln('Elements wider than the screen: ${over.join(', ')}');
          final broken = (j['brokenImages'] as List?) ?? <dynamic>[];
          b.writeln('Broken images: ${broken.isEmpty ? 'none' : broken.join(', ')}');
          b.writeln('Counts: ${j['counts']}; tiny text elements (<11px): ${j['tinyTextElements']}');
          b.writeln('Colors: ${j['bodyColors']}');
          b.writeln('Headings:\n${((j['headings'] as List?) ?? <dynamic>[]).join('\n')}');
          b.writeln('Top-level layout:\n${((j['layout'] as List?) ?? <dynamic>[]).join('\n')}');
          b.writeln('Visible text:\n${j['text']}');
        } catch (_) {
          b.writeln(raw.toString());
        }
        b.writeln('\nScript errors / failed requests (${logs.length}):');
        b.writeln(logs.isEmpty ? 'none' : logs.join('\n'));
        return b.toString();
      });

  /// Runs JavaScript in the page and returns the result as text.
  Future<String> evalJs(String js) => _serial(() async => (await _eval(js)).toString());

  Future<void> goTo(String address) async {
    needed.value = true;
    await controller.loadRequest(Uri.parse(address));
  }

  // ------------------------------------------------------------------ image upload (Google Lens)

  /// Gives [path] to the next file chooser the page opens, and clicks the page's file input.
  Future<bool> uploadFile(String path) async {
    _fileToUpload = path;
    try {
      final r = await _eval('''
(function(){var i=document.querySelector('input[type=file]');if(i){i.click();return 'ok';}
 var a=[].slice.call(document.querySelectorAll('a,button,div[role=button],span')).filter(function(e){return /upload a file|upload|تحميل|загруз/i.test((e.innerText||'')+'');})[0];
 if(a){a.click();return 'ok';}return 'none';})()
''');
      return r.toString().contains('ok');
    } catch (_) {
      return false;
    }
  }
}

/// Title, address and visible text of whatever [c] shows now.
Future<String> pageText(WebViewController c, int maxChars) async {
  final raw = await c.runJavaScriptReturningResult(
      '(document.title||"") + "\\n" + location.href + "\\n\\n" + ((document.body && document.body.innerText) || "")');
  var text = raw.toString();
  if (text.startsWith('"')) {
    try {
      text = jsonDecode(text) as String;
    } catch (_) {}
  }
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return text.length > maxChars ? text.substring(0, maxChars) : text;
}
