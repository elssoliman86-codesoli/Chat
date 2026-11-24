import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'browser_cursor.dart';
import 'browser_identity.dart';
import 'devtools_log.dart';
import 'password_script.dart';
import 'saved_logins.dart';
import 'web_native.dart';

/// The browser always presents itself as desktop Chrome on Windows, so Facebook, WhatsApp Web and other sites
/// that check the device give their full computer version.
const String desktopUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// Only used for a moment by project_check, which tests how a web project looks on a phone.
const String phoneUserAgent = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

const String browserUserAgent = desktopUserAgent;

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

  /// Draw a visible mouse cursor in the page while the assistant clicks, types and drags.
  bool showCursor = true;

  /// Network requests and console output of the current page (the browser's DevTools), shown in the panel
  /// and readable by the model through browser_devtools.
  final DevLog dev = DevLog();
  final ValueNotifier<bool> devToolsOpen = ValueNotifier<bool>(false);

  /// Name of the browser the built-in one is presenting as (empty = the default). Shown in the toolbar.
  final ValueNotifier<String> identityName = ValueNotifier<String>('');

  /// Desktop mode by default; the person can switch to phone mode from the menu (Google signs in there),
  /// and project_check looks at a page like a phone for one look.
  bool _desktop = true;

  /// Whether the person chose phone mode.
  final ValueNotifier<bool> phoneMode = ValueNotifier<bool>(false);

  /// Sets the mode before the web view exists (from the saved setting).
  void restoreMode({required bool phone}) {
    phoneMode.value = phone;
    _desktop = !phone;
  }

  /// Switches between phone and computer mode and reloads the page so the site sends the right layout.
  Future<void> setPhoneMode(bool phone) async {
    phoneMode.value = phone;
    if (!_created) {
      _desktop = !phone;
      return;
    }
    await _setDesktop(!phone);
    unawaited(_prepareNative());
    try {
      await controller.reload();
    } catch (_) {}
  }

  /// The desktop identity the browser presents: the default, or the browser chosen in Settings.
  String _desktopUa = desktopUserAgent;
  bool _created = false;
  String get currentUserAgent => _desktopUa;

  /// Makes the built-in browser present itself as another browser (Firefox, Chrome, Tor Browser…). It stays
  /// the same built-in web view, inside the app and fully driven by the assistant — only the identity sites
  /// see changes. An empty [package] goes back to the default.
  Future<void> useIdentity({required String package, String label = '', String version = ''}) async {
    identityName.value = package.isEmpty ? '' : (label.isEmpty ? package : label);
    _desktopUa = package.isEmpty ? desktopUserAgent : identityUserAgent(package: package, label: label, version: version);
    if (!_created) return; // the web view is made later with this identity
    await _setDesktop(_desktop);
    try {
      await controller.reload();
    } catch (_) {}
  }

  Future<void> _setDesktop(bool on) async {
    _desktop = on;
    try {
      await controller.setUserAgent(on ? _desktopUa : phoneUserAgent);
    } catch (_) {}
  }

  /// Sets up the native side of the web view once it exists on screen (it is not there yet at the very
  /// first page start, so it is tried a few times).
  bool _nativeBusy = false;

  Future<void> _prepareNative() async {
    if (_nativeBusy) return;
    _nativeBusy = true;
    try {
      for (var i = 0; i < 4; i++) {
        final r = await WebNative.prepare(userAgent: _desktop ? _desktopUa : phoneUserAgent, desktop: _desktop);
        if (r != null && ((r['webViews'] as num?) ?? 0) > 0) return;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } finally {
      _nativeBusy = false;
    }
  }

  /// Shows a short message to the person (set by the app: a snackbar).
  void Function(String text)? onNotice;

  ({String host, String user, String pass})? _pending;
  int _pendingGen = 0;
  Timer? _sessionTimer;

  /// The page reported a submitted sign-in form. It is saved only once the password box is gone (the sign-in went
  /// through), so a wrong password is never kept.
  void _onPassword(String raw) {
    if (!SavedLogins.instance.enabled) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final pass = (j['pass'] ?? '').toString();
      final host = Uri.tryParse(url.value)?.host ?? '';
      if (pass.isEmpty || host.isEmpty) return;
      _pending = (host: host, user: (j['user'] ?? '').toString(), pass: pass);
      unawaited(_confirmLogin(++_pendingGen));
    } catch (_) {}
  }

  Future<void> _confirmLogin(int gen) async {
    for (final wait in const <int>[3, 4, 5]) {
      await Future<void>.delayed(Duration(seconds: wait));
      final p = _pending;
      if (gen != _pendingGen || p == null) return;
      bool boxStillThere;
      try {
        boxStillThere = (await controller.runJavaScriptReturningResult(passwordVisibleScript)).toString() == 'true';
      } catch (_) {
        continue;
      }
      if (boxStillThere) continue;
      _pending = null;
      if (SavedLogins.instance.remember(p.host, p.user, p.pass)) {
        onNotice?.call('Saved the login for ${SavedLogins.normalizeHost(p.host)}${p.user.isEmpty ? '' : ' (${p.user})'}');
      }
      unawaited(_keepSession(url.value));
      return;
    }
    if (gen == _pendingGen) _pending = null;
  }

  /// Keeps this site's cookies in the app (and on disk) so the sign-in survives closing the app.
  Future<void> _keepSession(String u) async {
    final origin = SavedLogins.originOf(u);
    if (origin.isEmpty) return;
    try {
      SavedLogins.instance.rememberCookies(origin, await WebNative.cookies(origin));
      unawaited(WebNative.flushCookies());
    } catch (_) {}
  }

  /// Fills the sign-in form with the login saved for this site.
  Future<void> _autofill(String u) async {
    if (!SavedLogins.instance.enabled) return;
    final host = Uri.tryParse(u)?.host ?? '';
    if (host.isEmpty) return;
    final found = SavedLogins.instance.forHost(host);
    if (found.isEmpty) return;
    try {
      await controller.runJavaScript(passwordFillScript(jsonEncode(<String, String>{'u': found.first.user, 'p': found.first.pass})));
    } catch (_) {}
  }

  Future<void> _injectScripts() async {
    try {
      if (SavedLogins.instance.enabled) await controller.runJavaScript(passwordWatchScript);
      await controller.runJavaScript(devToolsScript);
      await controller.runJavaScript(omniCursorScript);
      if (_desktop) await controller.runJavaScript(desktopViewportScript);
    } catch (_) {}
  }

  /// The DevTools data as text for the model.
  String devtoolsReport({String kind = 'all', String filter = '', int? id}) => dev.report(kind: kind, filter: filter, id: id);

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
    _created = true;
    // Sign-ins done without loading a new page (an app-style site) set their cookies later; keep them too.
    _sessionTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (url.value.isNotEmpty) unawaited(_keepSession(url.value));
    });
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktop ? _desktopUa : phoneUserAgent)
      ..addJavaScriptChannel('OmniDev', onMessageReceived: (m) => dev.handle(m.message))
      ..addJavaScriptChannel('OmniPass', onMessageReceived: (m) => _onPassword(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) => progress.value = p,
        onPageStarted: (u) {
          _navigating = true;
          url.value = u;
          dev.newPage();
          _injectScripts();
          _prepareNative();
        },
        onPageFinished: (u) async {
          _navigating = false;
          url.value = u;
          _injectScripts();
          _prepareNative();
          unawaited(_keepSession(u));
          unawaited(_autofill(u));
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
    await _settle(maxMs: 2500, startMs: 100);
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
 var vh=innerHeight,vw=innerWidth;
 var sel='a[href],button,input,textarea,select,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=switch],[role=option],[role=combobox],[onclick],summary,[contenteditable=true],[contenteditable=""]';
 var els=[].slice.call(document.querySelectorAll(sel));
 function vis(e){var r=e.getBoundingClientRect();if(r.width<2||r.height<2)return false;var s=getComputedStyle(e);if(s.visibility==='hidden'||s.display==='none'||parseFloat(s.opacity)===0)return false;return r.bottom>-vh*0.3&&r.right>0&&r.top<vh*2.5&&r.left<vw;}
 function inView(r){return r.bottom>0&&r.top<vh&&r.right>0&&r.left<vw;}
 // a dialog / overlay on top: everything outside it is blocked, so look inside it first
 var dlg=null,dl=document.querySelectorAll('dialog[open],[role=dialog],[role=alertdialog],[aria-modal=true]');
 for(var d=0;d<dl.length;d++){var rr=dl[d].getBoundingClientRect();if(rr.width>40&&rr.height>40&&vis(dl[d])){dlg=dl[d];}}
 var items=[];
 for(var i=0;i<els.length;i++){var e=els[i];if(!vis(e))continue;var r=e.getBoundingClientRect();
  items.push({e:e,r:r,v:inView(r),m:dlg?dlg.contains(e):false,i:i});}
 items.sort(function(a,b){if(a.m!==b.m)return a.m?-1:1;if(a.v!==b.v)return a.v?-1:1;return a.i-b.i;});
 var out=[],n=0,rest=0;
 var active=document.activeElement;
 var submitWords=/\b(send|submit|post|reply|publish|save|done|next|continue|search|go|login|log in|sign in|share|tweet|comment|add|create|ok|confirm|apply)\b|إرسال|ارسال|نشر|حفظ|التالي|بحث|دخول|تسجيل|تأكيد|موافق|تعليق|مشاركة/i;
 for(var k=0;k<items.length;k++){var it=items[k];
  if(n>=110){rest++;continue;}
  var e=it.e,r=it.r;e.setAttribute('data-oid',String(n));
  var tag=e.tagName.toLowerCase();var type=e.getAttribute('type')||'';
  var t=(e.innerText||e.value||e.getAttribute('aria-label')||e.placeholder||e.title||e.alt||'').trim().replace(/\s+/g,' ').slice(0,80);
  var extra='';
  if(tag==='a'){extra=' -> '+(e.getAttribute('href')||'').slice(0,70);}
  var flags=[];
  if(!it.v)flags.push('below');
  if(it.m)flags.push('in dialog');
  if(e===active)flags.push('focused');
  if(e.disabled||e.getAttribute('aria-disabled')==='true')flags.push('disabled');
  if(e.checked===true||e.getAttribute('aria-checked')==='true'||e.getAttribute('aria-selected')==='true')flags.push('checked');
  if(e.required)flags.push('required');
  if(tag==='select'){var o=e.options[e.selectedIndex];extra=' selected="'+(o?o.text:'').slice(0,40)+'"';}
  else if(tag==='input'||tag==='textarea'||e.isContentEditable){
   var val=e.isContentEditable?(e.innerText||''):(e.value||'');
   if(type==='password')extra=val?' value=(filled)':' empty';
   else if(type==='checkbox'||type==='radio'||type==='submit'||type==='button'){}
   else extra=val?' value="'+String(val).replace(/\s+/g,' ').slice(0,60)+'"':' empty';
   if(tag==='textarea'||e.isContentEditable||/^(text|search|email|url|tel|number|)$/.test(type))t=(e.getAttribute('aria-label')||e.placeholder||e.name||e.title||'').trim().slice(0,60);
  }
  var sub=(tag==='button'||tag==='input'||e.getAttribute('role')==='button')&&(type==='submit'||submitWords.test(t))?' [send/submit]':'';
  var box=' @'+Math.round(r.left)+','+Math.round(r.top)+' '+Math.round(r.width)+'x'+Math.round(r.height);
  out.push('['+n+'] '+tag+(type?'('+type+')':'')+(t?' "'+t+'"':'')+extra+(flags.length?' {'+flags.join(', ')+'}':'')+sub+box);n++;}
 var root=dlg||document.body;
 var text=(root?root.innerText:'').replace(/[ \t]+\n/g,'\n').replace(/\n{3,}/g,'\n\n').slice(0,3800);
 var sh=Math.max(document.documentElement.scrollHeight,document.body?document.body.scrollHeight:0);
 var sy=Math.round(window.scrollY||document.documentElement.scrollTop||0);
 var pos=sh<=vh+8?'whole page fits on screen':('scrolled '+Math.round(100*sy/Math.max(1,sh-vh))+'% ('+(sy+vh>=sh-8?'at the bottom':(sy<8?'at the top':'in the middle'))+'), page is '+Math.round(sh/vh*10)/10+' screens tall');
 return JSON.stringify({title:document.title,url:location.href,text:text,dialog:!!dlg,pos:pos,more:rest,elements:out,
  sig:location.href+'|'+(document.body?document.body.innerText.length:0)+'|'+document.getElementsByTagName('*').length+'|'+(dlg?1:0)});
})()
''';

  /// A short fingerprint of the page; compared before and after an action to tell whether anything changed.
  static const String _sigJs = r'''
(function(){var b=document.body;var t=b?b.innerText:'';var h=0;for(var i=0;i<t.length&&i<6000;i++){h=(h*31+t.charCodeAt(i))|0;}
 return location.href+'|'+document.readyState+'|'+(b?t.length:0)+'|'+h+'|'+document.getElementsByTagName('*').length+'|'+document.querySelectorAll('input,textarea').length;})()
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

  /// A text description of the page the way a person sees it: where they are on the page, whether a dialog covers it,
  /// the text, and the clickable things (what is on screen first, then what is below), with their state.
  Future<String> snapshot() async {
    final raw = await _eval(_snapshotJs);
    try {
      final j = jsonDecode(raw as String) as Map<String, dynamic>;
      final b = StringBuffer();
      b.writeln('Page: ${j['title']}\n${j['url']}\n${j['pos']}');
      if (j['dialog'] == true) b.writeln('A dialog or popup is open on top: only things inside it can be used until it is closed.');
      b.writeln('\nVisible text${j['dialog'] == true ? ' (of the dialog)' : ''}:\n${j['text']}\n');
      b.writeln('Elements (number for browser_click / browser_type; {below} = not on screen yet, scroll to it; '
          '[send/submit] = looks like the button that sends or confirms; "@x,y wxh" = position and size in pixels):');
      for (final e in (j['elements'] as List)) {
        b.writeln(e);
      }
      final more = (j['more'] as num?)?.toInt() ?? 0;
      if (more > 0) b.writeln('… and $more more further down (scroll to see them).');
      return b.toString();
    } catch (_) {
      return raw.toString();
    }
  }

  Future<String> _sig() async {
    try {
      return (await _eval(_sigJs)).toString();
    } catch (_) {
      return '';
    }
  }

  /// Waits like a person who watches the screen: for a page that is loading, then until it stops changing.
  /// Returns as soon as things are still, so a quick page costs ~0.3 s and a slow one costs what it needs.
  Future<void> _settle({int maxMs = 3500, int startMs = 200}) async {
    await Future<void>.delayed(Duration(milliseconds: startMs));
    final clock = Stopwatch()..start();
    // A navigation started by the action: wait for it (up to 15 s) rather than reading half a page.
    final l = _loaded;
    if (_navigating && l != null && !l.isCompleted) {
      try {
        await l.future.timeout(const Duration(seconds: 15));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    var last = '';
    var same = 0;
    while (clock.elapsedMilliseconds < maxMs) {
      final s = await _sig();
      if (s == last && s.isNotEmpty && s.contains('|complete|')) {
        same++;
        if (same >= 2) return;
      } else {
        same = 0;
        last = s;
      }
      await Future<void>.delayed(const Duration(milliseconds: 130));
    }
  }

  bool _navigating = false;

  /// "Changed" / "nothing changed" line for the result of an action, from the fingerprints before and after.
  String _change(String before, String after) {
    if (before.isEmpty || after.isEmpty) return '';
    final b = before.split('|');
    final a = after.split('|');
    if (b.isNotEmpty && a.isNotEmpty && b.first != a.first) return 'Result: the page navigated to ${a.first}';
    if (before == after) return 'Result: NOTHING visibly changed on the page (the click may have missed, the control may be disabled, or the page needs another step).';
    return 'Result: the page content changed.';
  }

  /// Text typed into a box and not yet sent (no Enter, no button pressed since). The agent loop checks it before ending.
  String unsentText = '';

  bool get hasUnsentText => unsentText.isNotEmpty;

  Future<String> open(String address) => _serial(() async {
        _revealIfWanted();
        var a = address.trim();
        if (!a.startsWith('http')) a = 'https://$a';
        unsentText = '';
        await _load(a);
        return snapshot();
      });

  Future<String> read() => _serial(snapshot);

  /// Glides the visible cursor to element [id] (scrolling it into view first) and waits for the glide to
  /// finish. Returns false when the element is not there. Does nothing when the cursor is switched off.
  Future<bool> _cursorGo(int id, String label) async {
    if (!showCursor) return true;
    try {
      await controller.runJavaScript(omniCursorScript);
      final r = await _eval('''
(function(id,l){var e=document.querySelector('[data-oid="'+id+'"]');if(!e)return 'no';
 e.scrollIntoView({block:'center',behavior:'instant'});
 if(window.__omniCursor)window.__omniCursor.go(e,l);return 'ok';})($id,${jsonEncode(label)})
''');
      if (r.toString().contains('no')) return false;
      await Future<void>.delayed(const Duration(milliseconds: 360));
    } catch (_) {}
    return true;
  }

  Future<String> click(int id) => _serial(() async {
        _revealIfWanted();
        await _cursorGo(id, 'Click');
        final before = await _sig();
        _loaded = Completer<void>();
        final r = await _eval('''
(function(id){var e=document.querySelector('[data-oid="'+id+'"]');if(!e)return 'Element $id not found. Read the page again.';
 e.scrollIntoView({block:'center'});if(e.focus)e.focus();if(window.__omniCursor)window.__omniCursor.press();
 ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){e.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,view:window}));});
 return 'Clicked: '+((e.innerText||e.getAttribute('aria-label')||e.tagName)+'').slice(0,60);})($id)
''');
        if (!r.toString().startsWith('Element')) unsentText = '';
        await _settle();
        final after = await _sig();
        final shot = await snapshot();
        return '$r\n${_change(before, after)}\n\n$shot';
      });

  Future<String> type(int id, String text, bool submit) => _serial(() async {
        _revealIfWanted();
        if (await _cursorGo(id, 'Type') && showCursor && text.isNotEmpty) {
          try {
            if (text.length > 1) {
              final ms = await _eval('''
(function(id,text){var e=document.querySelector('[data-oid="'+id+'"]');if(!e||!window.__omniCursor)return 0;
 window.__omniCursor.press();return window.__omniCursor.typeInto(e,text,600);})($id,${jsonEncode(text)})
''');
              final wait = (double.tryParse(ms.toString().replaceAll('"', '')) ?? 0).round();
              await Future<void>.delayed(Duration(milliseconds: wait + 150));
            }
          } catch (_) {}
        }
        final t = jsonEncode(text);
        final before = await _sig();
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
        final missing = r.toString().startsWith('Element');
        await _settle(maxMs: submit ? 3500 : 800, startMs: submit ? 250 : 80);
        final after = await _sig();
        final shot = await snapshot();
        if (missing) return '$r\n\n$shot';
        if (submit) {
          unsentText = '';
          return '$r and pressed Enter.\n${_change(before, after)}\n\n$shot';
        }
        // Typed but not sent: say so, and point at the button that sends it, so the task is not left half done.
        final senders = shot.split('\n').where((l) => l.contains('[send/submit]') && !l.contains('{disabled')).take(3).toList();
        if (text.trim().isNotEmpty && (senders.isNotEmpty || shot.contains('textarea'))) {
          unsentText = text;
        }
        final hint = senders.isEmpty
            ? 'The text is typed but NOT sent yet. If it must be sent or saved, press Enter (type again with submit=true) or click the button that sends it.'
            : 'The text is typed but NOT sent yet. To send it, click: ${senders.join(' | ')}';
        return '$r.\n$hint\n\n$shot';
      });

  /// Drags an element by (dx, dy) screen pixels — a real pointer-down, several pointer-moves, then
  /// pointer-up, not a single jump, since most drag-based UIs (design canvases, sliders, reorderable
  /// lists) only register movement that comes as a sequence of small steps. Note: because these are
  /// script-dispatched events (not real touches), a page that specifically checks event.isTrusted before
  /// accepting a drag will ignore this — that is a real limit of browser automation, not a bug here.
  Future<String> drag(int id, int dx, int dy) => _serial(() async {
        _revealIfWanted();
        await _cursorGo(id, 'Drag');
        final r = await _eval('''
(function(id,dx,dy){
 var e=document.querySelector('[data-oid="'+id+'"]');if(!e)return 'Element '+id+' not found. Read the page again.';
 e.scrollIntoView({block:'center'});
 var r=e.getBoundingClientRect();var x0=r.left+r.width/2,y0=r.top+r.height/2;var steps=12;
 if(window.__omniCursor){window.__omniCursor.press();window.__omniCursor.move(x0+dx,y0+dy,550,'Drag');}
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
        await Future<void>.delayed(Duration(milliseconds: showCursor ? 700 : 600));
        return '$r\n\n${await snapshot()}';
      });

  Future<String> scroll(bool down) => _serial(() async {
        await _eval('window.scrollBy(0, ${down ? '' : '-'}Math.round(innerHeight*0.8)); "ok"');
        await _settle(maxMs: 1200, startMs: 150);
        return snapshot();
      });

  Future<String> back() => _serial(() async {
        _loaded = Completer<void>();
        unsentText = '';
        await controller.goBack();
        await _settle(maxMs: 3000, startMs: 250);
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
        // A web project is judged on how it looks on a phone, so the browser steps out of desktop mode for this one look.
        await _setDesktop(false);
        String raw;
        try {
          await _load(address);
          await Future<void>.delayed(Duration(milliseconds: waitMs));
          raw = (await _eval(_checkJs)).toString();
        } finally {
          await _setDesktop(!phoneMode.value);
        }
        final b = StringBuffer();
        try {
          final j = jsonDecode(raw) as Map<String, dynamic>;
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
