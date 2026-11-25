/// The page script that lets the app use a chat website (ChatGPT, Claude, Gemini, DeepSeek and similar) like a
/// person: type into the message box, press send, wait for the answer to finish, read it back, and attach an image.
/// It finds things by what they look like (a message box, a send button, a stop button), not by one site's markup,
/// so it keeps working when a site changes its design. Plain string, installed once per page as `window.__oc`.
library;

const String webChatDriverJs = r'''
(function(){
 if (window.__oc && window.__oc.v === 1) return;
 function vis(e){
  if (!e || !e.getBoundingClientRect) return false;
  var r = e.getBoundingClientRect();
  if (r.width < 2 || r.height < 2) return false;
  var s = getComputedStyle(e);
  return s.visibility !== 'hidden' && s.display !== 'none';
 }
 function label(e){
  return ((e.getAttribute('aria-label') || '') + ' ' + (e.getAttribute('data-testid') || '') + ' ' + (e.getAttribute('title') || '') + ' ' + (e.innerText || '')).toLowerCase();
 }
 function area(e){ var r = e.getBoundingClientRect(); return r.width * r.height; }
 function input(){
  var all = [].slice.call(document.querySelectorAll('textarea,[contenteditable=""],[contenteditable="true"],[contenteditable="plaintext-only"],[role=textbox]'));
  var c = all.filter(function(e){ return vis(e) && !e.disabled && !e.readOnly && !e.closest('[aria-hidden="true"]'); });
  if (!c.length) c = [].slice.call(document.querySelectorAll('input[type=text],input[type=search],input:not([type])')).filter(vis);
  // the message box sits at the bottom of the screen: take the lowest, then the biggest
  c.sort(function(a, b){
   var ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
   return (rb.bottom - ra.bottom) || (area(b) - area(a));
  });
  return c[0] || null;
 }
 function textOf(el){ return el.tagName === 'TEXTAREA' || el.tagName === 'INPUT' ? (el.value || '') : (el.innerText || ''); }
 var NOT_SEND = /attach|upload|voice|mic|record|stop|dictat|search|plus|إرفاق|ملف|صوت|ميكروفون|بحث|menu|more|copy|share|model|new chat|settings/;
 function isSend(b){
  if (b.disabled || b.getAttribute('aria-disabled') === 'true') return false;
  var l = label(b);
  if (NOT_SEND.test(l)) return false;
  return /send|submit|إرسال|ارسال|enviar|envoyer|senden|отправ|composer-submit|send-button|arrow-up|paper-plane/.test(l);
 }
 function guess(bs, el){
  var er = el.getBoundingClientRect(), ec = (er.top + er.bottom) / 2, best = null, bestRight = -1;
  bs.forEach(function(b){
   if (b.disabled || b.getAttribute('aria-disabled') === 'true') return;
   if (NOT_SEND.test(label(b))) return;
   var r = b.getBoundingClientRect(), c = (r.top + r.bottom) / 2;
   if (Math.abs(c - ec) > Math.max(120, er.height)) return;
   if (r.right > bestRight) { best = b; bestRight = r.right; }
  });
  return best;
 }
 function generating(){
  var bs = document.querySelectorAll('button,[role=button]');
  for (var i = 0; i < bs.length; i++) {
   if (!vis(bs[i])) continue;
   var l = label(bs[i]);
   if (/(^|[^a-z])(stop|stop-button|stop generating|stop streaming)([^a-z]|$)|إيقاف/.test(l) && !/stop sharing|stop recording|stop voice|stop listening/.test(l)) return true;
  }
  return !!document.querySelector('[data-is-streaming="true"],.result-streaming');
 }
 var SELS = ['[data-message-author-role="assistant"]', '[data-is-streaming]', '.font-claude-response', '.font-claude-message',
  'model-response', '.model-response-text', '.ds-markdown', '[data-content="ai-message"]', 'div[id^="markdown-content"]',
  '.markdown', '.prose', '[class*="markdown"]'];
 function nodes(){
  for (var i = 0; i < SELS.length; i++) {
   var l = [].slice.call(document.querySelectorAll(SELS[i])).filter(function(e){ return !e.closest('textarea,[contenteditable="true"],[contenteditable=""]'); });
   if (!l.length) continue;
   // keep the outermost ones (a markdown box inside a message box is the same message)
   l = l.filter(function(e){ return !l.some(function(o){ return o !== e && o.contains(e); }); });
   if (l.length) return l;
  }
  return [];
 }
 function md(n){
  if (n.nodeType === 3) return n.nodeValue;
  if (n.nodeType !== 1) return '';
  var t = n.tagName;
  if (/^(SCRIPT|STYLE|SVG|BUTTON|NOSCRIPT|TEXTAREA)$/i.test(t)) return '';
  if (n.getAttribute && n.getAttribute('aria-hidden') === 'true') return '';
  function kids(){ var s = ''; for (var c = n.firstChild; c; c = c.nextSibling) s += md(c); return s; }
  if (t === 'PRE') {
   var code = n.querySelector('code');
   var txt = (code || n).innerText || (code || n).textContent || '';
   var lang = '';
   var cls = ((code && code.className) || n.className || '') + '';
   var m = /(?:language|lang)-([a-z0-9#+-]+)/i.exec(cls);
   if (m) lang = m[1];
   return '\n```' + lang + '\n' + txt.replace(/\n+$/, '') + '\n```\n';
  }
  if (t === 'BR') return '\n';
  if (t === 'CODE') return '`' + (n.innerText || n.textContent || '') + '`';
  if (t === 'STRONG' || t === 'B') return '**' + kids() + '**';
  if (/^H[1-6]$/.test(t)) return '\n' + '#'.repeat(parseInt(t.charAt(1), 10)) + ' ' + kids().trim() + '\n';
  if (t === 'LI') {
   var p = n.parentNode, idx = 0;
   if (p && p.tagName === 'OL') { idx = 1; for (var s = n.previousElementSibling; s; s = s.previousElementSibling) idx++; }
   return (idx ? idx + '. ' : '- ') + kids().trim() + '\n';
  }
  if (t === 'UL' || t === 'OL') return '\n' + kids() + '\n';
  if (t === 'TR') {
   var cells = [].slice.call(n.children).map(function(c){ return md(c).trim().replace(/\n+/g, ' '); });
   return '| ' + cells.join(' | ') + ' |\n';
  }
  if (t === 'TABLE') return '\n' + kids() + '\n';
  if (t === 'P' || t === 'DIV' || t === 'SECTION' || t === 'BLOCKQUOTE') {
   var inner = kids();
   if (t === 'BLOCKQUOTE') inner = inner.replace(/^/gm, '> ');
   return inner.replace(/\n*$/, '') + '\n';
  }
  return kids();
 }
 function lastText(){
  var l = nodes();
  if (!l.length) return '';
  return md(l[l.length - 1]).replace(/\n{3,}/g, '\n\n').trim();
 }
 function hash(s){
  var h = 0, n = Math.min(s.length, 6000), from = s.length - n;
  for (var i = 0; i < n; i++) h = (h * 31 + s.charCodeAt(from + i)) | 0;
  return h;
 }
 function loginWall(){
  var t = (document.body ? document.body.innerText : '').slice(0, 6000);
  if (input()) return '';
  if (/verify you are human|just a moment|checking your browser|are you a robot|human verification/i.test(t)) return 'human';
  if (/\/(login|signin|sign-in|auth)(\/|\?|$)|accounts\.google\.com|login\.microsoftonline|appleid\.apple/i.test(location.href)) return 'login';
  var els = [].slice.call(document.querySelectorAll('a,button')).filter(vis);
  for (var i = 0; i < els.length; i++) {
   var x = (els[i].innerText || '').trim();
   if (/^(log\s?in|sign\s?in|sign\s?up|continue with google|continue with email|تسجيل الدخول|تسجيل|دخول)$/i.test(x)) return 'login';
  }
  return '';
 }
 var up = null;
 window.__oc = {
  v: 1,
  hasInput: function(){ return !!input(); },
  // What the page shows, for the test screen: address, title, whether a message box / sign-in wall is there.
  info: function(){
   var t = (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').slice(0, 300);
   return JSON.stringify({ url: location.href, title: document.title, input: !!input(), wall: loginWall(), full: this.full(),
    gen: generating(), files: document.querySelectorAll('input[type=file]').length, text: t });
  },
  // The site says the conversation is full (context limit, too long, start a new chat). Looks only at notices and the
  // message box, never at the answers themselves, which may talk about such things.
  full: function(){
   var re = /(conversation|chat|thread)[^.]{0,40}(too long|is full|has reached|reached (the|its) (maximum|max|length|limit))|maximum (conversation )?length|context (window|length|limit)[^.]{0,30}(reached|exceeded|full)|(start|begin|open) a new (chat|conversation)|message (is )?too long|exceeds? the (maximum|max|limit)|المحادثة[^.]{0,30}(طويلة|وصلت|ممتلئة)|ابدأ محادثة جديدة|ابدء محادثة جديدة|حد المحادثة/i;
   var notes = [].slice.call(document.querySelectorAll('[role=alert],[role=status],[aria-live],[class*="banner"],[class*="toast"],[class*="notice"],[class*="warning"],[class*="error"]')).filter(vis);
   for (var i = 0; i < notes.length; i++) {
    if (notes[i].closest('[data-message-author-role],.markdown,.prose,[data-is-streaming]')) continue;
    if (re.test((notes[i].innerText || '').slice(0, 400))) return true;
   }
   var el = input();
   if (!el) {
    var dis = [].slice.call(document.querySelectorAll('textarea,[role=textbox]')).filter(function(e){
     return vis(e) && (e.disabled || e.readOnly || e.getAttribute('aria-disabled') === 'true');
    });
    if (dis.length && !generating()) return true;
   }
   if (el && (el.disabled || el.getAttribute('aria-disabled') === 'true' || el.readOnly)) return true;
   if (el && re.test(((el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('data-placeholder') || '')).slice(0, 300))) return true;
   return false;
  },
  wall: loginWall,
  put: function(text){
   var el = input();
   if (!el) return 'no-input';
   el.focus();
   if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
    var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    var d = Object.getOwnPropertyDescriptor(proto, 'value');
    if (d && d.set) d.set.call(el, text); else el.value = text;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    return 'ok:' + (el.value || '').length;
   }
   var sel = window.getSelection(), rg = document.createRange();
   rg.selectNodeContents(el); sel.removeAllRanges(); sel.addRange(rg);
   document.execCommand('delete', false, null);
   var ok = false;
   try { ok = document.execCommand('insertText', false, text); } catch (e) {}
   var have = (el.innerText || '').replace(/\s+/g, '').length, want = text.replace(/\s+/g, '').length;
   if (!ok || have < want * 0.8) {
    try {
     var dt = new DataTransfer();
     dt.setData('text/plain', text);
     el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    } catch (e) {}
    have = (el.innerText || '').replace(/\s+/g, '').length;
   }
   return 'ok:' + have;
  },
  inputLen: function(){ var el = input(); return el ? textOf(el).replace(/\s+/g, '').length : -1; },
  send: function(mode){
   var el = input();
   if (!el) return 'no-input';
   if (mode !== 'enter') {
    var scope = el;
    for (var up = 0; up < 8 && scope.parentElement; up++) {
     scope = scope.parentElement;
     var bs = [].slice.call(scope.querySelectorAll('button,[role=button],input[type=submit]')).filter(vis);
     if (!bs.length) continue;
     var named = bs.filter(isSend)[0];
     if (named) { named.click(); return 'button'; }
     if (mode === 'guess') {
      var g = guess(bs, el);
      if (g) { g.click(); return 'guess'; }
     }
    }
    if (mode === 'guess') return 'none';
    return 'none';
   }
   el.focus();
   ['keydown', 'keypress', 'keyup'].forEach(function(t){
    el.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
   });
   return 'enter';
  },
  state: function(){
   var l = nodes(), text = l.length ? lastText() : '', body = '';
   if (!l.length) body = document.body ? document.body.innerText : '';
   var src = l.length ? text : body;
   return JSON.stringify({ gen: generating(), count: l.length, len: src.length, h: hash(src), inLen: this.inputLen() });
  },
  last: function(){
   var t = lastText();
   if (t) return t;
   return '';
  },
  bodyLen: function(){ return document.body ? document.body.innerText.length : 0; },
  // For a site whose answers are not found by markup: the page text that came after the question just sent.
  bodyTail: function(prompt, baseLen){
   var t = document.body ? document.body.innerText : '';
   var tail = (prompt || '').slice(-80);
   var i = tail ? t.indexOf(tail, Math.max(0, (baseLen || 0) - 5)) : -1;
   return (i >= 0 ? t.slice(i + tail.length) : t.slice(Math.max(0, baseLen || 0))).trim();
  },
  upStart: function(name, mime){ up = { name: name, mime: mime, parts: [] }; return 'ok'; },
  upPart: function(s){ if (up) up.parts.push(s); return up ? up.parts.length : -1; },
  upFinish: function(){
   if (!up) return 'no-upload';
   var bin = atob(up.parts.join(''));
   var arr = new Uint8Array(bin.length);
   for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
   var file = new File([arr], up.name, { type: up.mime });
   up = null;
   var inputs = [].slice.call(document.querySelectorAll('input[type=file]'));
   var pick = inputs.filter(function(f){ return !f.accept || /image|\*/.test(f.accept); })[0] || inputs[0];
   if (pick) {
    var dt = new DataTransfer();
    dt.items.add(file);
    pick.files = dt.files;
    pick.dispatchEvent(new Event('input', { bubbles: true }));
    pick.dispatchEvent(new Event('change', { bubbles: true }));
    return 'file-input';
   }
   var el = input();
   if (el) {
    el.focus();
    var dt2 = new DataTransfer();
    dt2.items.add(file);
    el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt2, bubbles: true, cancelable: true }));
    return 'paste';
   }
   return 'none';
  },
  previews: function(name){
   var n = document.querySelectorAll('img[src^="blob:"],img[src^="data:image"]').length;
   var named = name && document.body && document.body.innerText.indexOf(name) >= 0 ? 1 : 0;
   return n + named;
  }
 };
})();
''';
