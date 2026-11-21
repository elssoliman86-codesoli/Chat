import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// One network request seen by the page: filled in as the request starts and then finishes.
class NetEntry {
  NetEntry({required this.id, required this.method, required this.url, required this.kind, required this.startedAt});

  final int id;
  String method;
  String url;

  /// fetch, xhr, or the resource type (script, img, css, ...).
  String kind;
  final int startedAt;
  int status = 0;
  int durationMs = 0;
  String contentType = '';
  String requestHeaders = '';
  String requestBody = '';
  String responseHeaders = '';
  String responseBody = '';
  String error = '';
  bool done = false;

  bool get failed => error.isNotEmpty || status >= 400;

  String get statusLabel => error.isNotEmpty ? 'ERR' : (done ? '$status' : '…');

  String get path {
    final u = Uri.tryParse(url);
    if (u == null || !u.hasAuthority) return url;
    final p = u.path.isEmpty ? '/' : u.path;
    return '${u.host}$p${u.hasQuery ? '?${u.query}' : ''}';
  }

  /// One line for a list.
  String get line => '#$id $method $statusLabel ${done ? '${durationMs}ms' : ''} [$kind] $url'.replaceAll('  ', ' ');

  /// Everything known about the request, as text for the screen and for the model.
  String get detail {
    final b = StringBuffer('$method $url\n');
    b.writeln(error.isNotEmpty ? 'Failed: $error' : 'Status: ${done ? status : 'pending'}${durationMs > 0 ? ' in ${durationMs}ms' : ''}');
    if (contentType.isNotEmpty) b.writeln('Content-Type: $contentType');
    if (requestHeaders.isNotEmpty) b.writeln('\nRequest headers:\n$requestHeaders');
    if (requestBody.isNotEmpty) b.writeln('\nRequest body:\n$requestBody');
    if (responseHeaders.isNotEmpty) b.writeln('\nResponse headers:\n${responseHeaders.trim()}');
    if (responseBody.isNotEmpty) b.writeln('\nResponse body:\n$responseBody');
    return b.toString().trimRight();
  }
}

class ConsoleEntry {
  ConsoleEntry(this.level, this.text, this.at);

  /// log, info, warn, error or debug.
  final String level;
  final String text;
  final int at;

  String get line => '[$level] $text';
}

/// The browser's DevTools data: network requests and console output of the current page, collected by a
/// script injected into every page. Shown to the person in a panel and readable by the model.
class DevLog {
  static const int maxEntries = 400;

  final List<NetEntry> net = <NetEntry>[];
  final List<ConsoleEntry> console = <ConsoleEntry>[];

  /// Bumped (at most a few times a second) whenever anything changes, for the panel to redraw.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final Map<int, NetEntry> _byId = <int, NetEntry>{};
  int _nextId = 0;
  Timer? _tick;

  void _changed() {
    _tick ??= Timer(const Duration(milliseconds: 200), () {
      _tick = null;
      revision.value++;
    });
  }

  void clear() {
    net.clear();
    console.clear();
    _byId.clear();
    _changed();
  }

  /// A new page was opened: start a fresh log, like DevTools does without "Preserve log".
  void newPage() => clear();

  NetEntry _add(NetEntry e) {
    net.add(e);
    if (net.length > maxEntries) {
      final old = net.removeAt(0);
      _byId.removeWhere((_, v) => identical(v, old));
    }
    return e;
  }

  /// Handles one JSON message posted by the injected script.
  void handle(String raw) {
    Map<String, dynamic> j;
    try {
      final d = jsonDecode(raw);
      if (d is! Map) return;
      j = d.cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (j['t']) {
      case 'c':
        console.add(ConsoleEntry((j['l'] ?? 'log').toString(), (j['m'] ?? '').toString(), now));
        if (console.length > maxEntries) console.removeAt(0);
        break;
      case 'n':
        final key = (j['id'] as num?)?.toInt() ?? -1;
        final stage = j['s'];
        if (stage == 'start') {
          final e = _add(NetEntry(
              id: ++_nextId, method: (j['m'] ?? 'GET').toString(), url: (j['u'] ?? '').toString(), kind: (j['k'] ?? 'fetch').toString(), startedAt: now));
          e.requestHeaders = (j['rh'] ?? '').toString();
          e.requestBody = (j['rb'] ?? '').toString();
          _byId[key] = e;
        } else {
          final e = _byId[key];
          if (e == null) break;
          e.durationMs = (j['d'] as num?)?.toInt() ?? 0;
          e.done = true;
          if (stage == 'err') {
            e.error = (j['e'] ?? 'failed').toString();
          } else {
            e.status = (j['st'] as num?)?.toInt() ?? 0;
            e.contentType = (j['ct'] ?? '').toString();
            e.responseHeaders = (j['h'] ?? '').toString();
            e.responseBody = (j['b'] ?? '').toString();
          }
          _byId.remove(key);
        }
        break;
      case 'r':
        final e = _add(NetEntry(
            id: ++_nextId, method: 'GET', url: (j['u'] ?? '').toString(), kind: (j['k'] ?? 'resource').toString(), startedAt: now));
        e.done = true;
        e.status = 200;
        e.durationMs = (j['d'] as num?)?.toInt() ?? 0;
        break;
      default:
        return;
    }
    _changed();
  }

  List<NetEntry> filtered(String query, {bool onlyFailed = false}) {
    final q = query.trim().toLowerCase();
    return net.where((e) => (!onlyFailed || e.failed) && (q.isEmpty || e.url.toLowerCase().contains(q) || e.method.toLowerCase() == q)).toList();
  }

  /// A text report for the model: [kind] is network, console or all; [filter] keeps only requests whose
  /// address contains it; [id] returns the full detail (headers and bodies) of one request.
  String report({String kind = 'all', String filter = '', int? id, int maxChars = 9000}) {
    if (id != null) {
      for (final e in net) {
        if (e.id == id) {
          final d = e.detail;
          return d.length > maxChars ? '${d.substring(0, maxChars)}\n[... cut]' : d;
        }
      }
      return 'No request #$id in the log (it only keeps the current page\'s last $maxEntries).';
    }
    final b = StringBuffer();
    if (kind == 'all' || kind == 'network') {
      final list = filtered(filter);
      b.writeln('Network (${list.length}${filter.isEmpty ? '' : ' matching "$filter"'} of ${net.length}):');
      if (list.isEmpty) b.writeln('  none');
      // Failures first, then the most recent requests.
      final failed = list.where((e) => e.failed).toList();
      final rest = list.where((e) => !e.failed).toList();
      final shown = <NetEntry>[...failed, ...rest.skip(rest.length > 60 ? rest.length - 60 : 0)];
      for (final e in shown) {
        b.writeln('  ${e.line}');
      }
      if (shown.length < list.length) b.writeln('  … ${list.length - shown.length} older requests not listed');
      b.writeln('Use browser_devtools with id=N for the headers and response body of one request.');
    }
    if (kind == 'all' || kind == 'console') {
      b.writeln('\nConsole (${console.length}):');
      if (console.isEmpty) b.writeln('  none');
      for (final c in console.skip(console.length > 80 ? console.length - 80 : 0)) {
        b.writeln('  ${c.line}');
      }
    }
    final out = b.toString().trimRight();
    return out.length > maxChars ? '${out.substring(0, maxChars)}\n[... cut]' : out;
  }
}

/// The script injected into every page: reports console output, errors, fetch and XMLHttpRequest calls
/// (with headers and bodies) and other loaded resources to the app through the OmniDev channel.
const String devToolsScript = r'''
(function(){
 if(window.__omniDev)return;window.__omniDev=true;
 var seq=0;
 function post(o){try{OmniDev.postMessage(JSON.stringify(o));}catch(e){}}
 function cut(s,n){s=String(s==null?'':s);return s.length>n?s.slice(0,n)+'...[+'+(s.length-n)+' chars]':s;}
 function show(a){try{return typeof a==='object'?JSON.stringify(a):String(a);}catch(e){return String(a);}}
 ['log','info','warn','error','debug'].forEach(function(l){
  var orig=console[l];
  console[l]=function(){try{post({t:'c',l:l,m:cut([].slice.call(arguments).map(show).join(' '),1500)});}catch(e){}return orig.apply(console,arguments);};
 });
 addEventListener('error',function(e){post({t:'c',l:'error',m:cut((e.message||'error')+' ('+(e.filename||'')+':'+(e.lineno||0)+')',1500)});});
 addEventListener('unhandledrejection',function(e){post({t:'c',l:'error',m:'Unhandled promise rejection: '+cut(e.reason&&e.reason.stack||e.reason,800)});});
 function headersText(h){
  var out=[];
  try{
   if(!h)return '';
   if(typeof h.forEach==='function'&&!Array.isArray(h)){h.forEach(function(v,k){out.push(k+': '+v);});}
   else if(Array.isArray(h)){h.forEach(function(p){out.push(p[0]+': '+p[1]);});}
   else{Object.keys(h).forEach(function(k){out.push(k+': '+h[k]);});}
  }catch(e){}
  return out.join('\n');
 }
 var textual=/json|text|xml|javascript|html|x-www-form|svg/i;
 var of=window.fetch;
 if(of){
  window.fetch=function(input,init){
   var id=++seq;
   var url=typeof input==='string'?input:((input&&input.url)||String(input));
   var method=String((init&&init.method)||(input&&input.method)||'GET').toUpperCase();
   var t0=Date.now();
   post({t:'n',id:id,s:'start',k:'fetch',m:method,u:cut(url,600),rh:headersText((init&&init.headers)||(input&&input.headers)),rb:init&&typeof init.body==='string'?cut(init.body,2000):''});
   return of.apply(this,arguments).then(function(r){
    var ct=r.headers.get('content-type')||'';
    var hs=headersText(r.headers);
    var done=function(txt){post({t:'n',id:id,s:'end',st:r.status,ct:ct,d:Date.now()-t0,h:hs,b:txt});};
    if(!ct||textual.test(ct)){r.clone().text().then(function(x){done(cut(x,4000));},function(){done('');});}
    else{done('[binary '+ct+']');}
    return r;
   },function(err){post({t:'n',id:id,s:'err',d:Date.now()-t0,e:String(err)});throw err;});
  };
 }
 var XP=XMLHttpRequest.prototype,oo=XP.open,os=XP.send,oh=XP.setRequestHeader;
 XP.open=function(m,u){this.__o={id:++seq,m:String(m).toUpperCase(),u:cut(u,600),h:[]};return oo.apply(this,arguments);};
 XP.setRequestHeader=function(k,v){try{this.__o.h.push(k+': '+v);}catch(e){}return oh.apply(this,arguments);};
 XP.send=function(b){
  var o=this.__o,x=this;
  if(o){
   var t0=Date.now();
   post({t:'n',id:o.id,s:'start',k:'xhr',m:o.m,u:o.u,rh:o.h.join('\n'),rb:typeof b==='string'?cut(b,2000):''});
   x.addEventListener('loadend',function(){
    var ct=x.getResponseHeader('content-type')||'';
    var txt='';
    try{txt=(x.responseType===''||x.responseType==='text')?cut(x.responseText,4000):'[binary '+x.responseType+']';}catch(e){}
    if(x.status===0){post({t:'n',id:o.id,s:'err',d:Date.now()-t0,e:'Network error or blocked'});}
    else{post({t:'n',id:o.id,s:'end',st:x.status,ct:ct,d:Date.now()-t0,h:x.getAllResponseHeaders(),b:txt});}
   });
  }
  return os.apply(this,arguments);
 };
 try{
  new PerformanceObserver(function(list){
   list.getEntries().forEach(function(e){
    if(e.initiatorType==='fetch'||e.initiatorType==='xmlhttprequest')return;
    post({t:'r',u:cut(e.name,600),k:e.initiatorType||'resource',d:Math.round(e.duration)});
   });
  }).observe({type:'resource',buffered:true});
 }catch(e){}
})();
''';

/// Makes a page lay out like on a desktop (a 1280 px wide layout) and then scales that layout to fit the
/// screen, so the whole page is visible instead of being pushed off to the right. The viewport tag is
/// kept even if the page rewrites it, and recomputed when the screen rotates.
const String desktopViewportScript = r'''
(function(){
 if(window.__omniDesktop)return;window.__omniDesktop=true;
 var W=1280,last='';
 function want(){
  var sw=(window.screen&&screen.width)||0;
  if(window.innerWidth&&(!sw||window.innerWidth<sw))sw=window.innerWidth;
  if(!sw||sw>=W)return 'width='+W+', initial-scale=1';
  var s=Math.floor(sw/W*1000)/1000;
  return 'width='+W+', initial-scale='+s+', minimum-scale='+s+', maximum-scale=5, user-scalable=yes';
 }
 function fix(){
  var h=document.head;if(!h)return;
  var m=document.querySelector('meta[name=viewport]');
  if(!m){m=document.createElement('meta');m.name='viewport';h.appendChild(m);}
  var c=want();
  if(m.content!==c){last=c;m.content=c;}
  var d=document.documentElement;
  if(d&&d.style.overflowX!=='hidden'){d.style.overflowX='hidden';}
 }
 function watch(){
  var h=document.head;
  if(!h)return false;
  fix();
  new MutationObserver(fix).observe(h,{childList:true,attributes:true,subtree:true,attributeFilter:['content','name']});
  return true;
 }
 if(!watch()){
  var o=new MutationObserver(function(){if(watch())o.disconnect();});
  o.observe(document.documentElement,{childList:true});
 }
 window.addEventListener('orientationchange',function(){setTimeout(fix,250);});
 window.addEventListener('load',fix);
})();
''';

