/// Page scripts for the browser's saved logins. Plain strings; the values go in through JSON.
library;

/// Watches sign-in forms. When the person submits one it tells the app the user name and password (channel
/// "OmniPass"). The app decides afterwards whether the sign-in worked (the password box is gone).
const String passwordWatchScript = r'''
(function(){
  if (window.__omniPassWatch) return;
  window.__omniPassWatch = true;
  function visible(e){
    if (!e || !e.getBoundingClientRect) return false;
    var r = e.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    var s = getComputedStyle(e);
    return s.visibility !== 'hidden' && s.display !== 'none';
  }
  var TEXTY = ['text','email','tel','url','number',''];
  function userBefore(pw){
    var scope = pw.form || document;
    var list = scope.querySelectorAll('input');
    var best = null;
    for (var i = 0; i < list.length; i++) {
      var e = list[i];
      if (e === pw) break;
      var t = (e.type || 'text').toLowerCase();
      if (TEXTY.indexOf(t) >= 0 && e.value && visible(e)) best = e;
    }
    return best;
  }
  function userField(){
    var list = document.querySelectorAll('input');
    var best = null;
    for (var i = 0; i < list.length; i++) {
      var e = list[i];
      var t = (e.type || 'text').toLowerCase();
      if (!e.value || !visible(e)) continue;
      var hint = ((e.autocomplete || '') + ' ' + (e.name || '') + ' ' + (e.id || '') + ' ' + (e.type || '')).toLowerCase();
      if (t === 'email' || /user|email|login|account|phone|identifier/.test(hint)) best = e;
    }
    return best;
  }
  function arm(){
    try {
      var pws = document.querySelectorAll('input[type=password]');
      for (var i = 0; i < pws.length; i++) {
        var pw = pws[i];
        if (!pw.value) continue;
        var uf = userBefore(pw);
        var u = uf ? uf.value : '';
        if (!u) {
          try {
            var s = JSON.parse(localStorage.getItem('__omni_u') || 'null');
            if (s && s.h === location.host && Date.now() - s.t < 900000) u = s.u;
          } catch (e) {}
        }
        OmniPass.postMessage(JSON.stringify({ user: u, pass: pw.value }));
        return;
      }
      // First step of a two-step sign-in: only the user name is on the page. Remember it for the password step.
      var f = userField();
      if (f && !document.querySelector('input[type=password]')) {
        try { localStorage.setItem('__omni_u', JSON.stringify({ h: location.host, u: f.value, t: Date.now() })); } catch (e) {}
      }
    } catch (e) {}
  }
  document.addEventListener('submit', function(){ arm(); }, true);
  document.addEventListener('click', function(ev){
    var t = ev.target;
    while (t && t !== document && !(t.tagName === 'BUTTON' || t.tagName === 'A' || (t.tagName === 'INPUT' && /submit|button|image/i.test(t.type)) || t.getAttribute && t.getAttribute('role') === 'button')) t = t.parentNode;
    if (t && t !== document) arm();
  }, true);
  document.addEventListener('keydown', function(ev){
    if (ev.key === 'Enter') arm();
  }, true);
})();
''';

/// True/false: is a password box visible on the page now (used to tell if a sign-in went through).
const String passwordVisibleScript = r'''
(function(){
  var l = document.querySelectorAll('input[type=password]');
  for (var i = 0; i < l.length; i++) {
    var r = l[i].getBoundingClientRect();
    var s = getComputedStyle(l[i]);
    if (r.width >= 2 && r.height >= 2 && s.visibility !== 'hidden' && s.display !== 'none') return true;
  }
  return false;
})()
''';

/// Fills the sign-in form with a saved login. [json] is {"u":"user","p":"password"}.
String passwordFillScript(String json) => '''
(function(c){
  var tries = 0;
  function visible(e){
    if (!e || !e.getBoundingClientRect) return false;
    var r = e.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    var s = getComputedStyle(e);
    return s.visibility !== 'hidden' && s.display !== 'none';
  }
  function setVal(e, v){
    var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    if (d && d.set) d.set.call(e, v); else e.value = v;
    e.dispatchEvent(new Event('input', { bubbles: true }));
    e.dispatchEvent(new Event('change', { bubbles: true }));
  }
  var TEXTY = ['text','email','tel','url','number',''];
  function looksLikeUser(e){
    var t = (e.type || 'text').toLowerCase();
    var hint = ((e.autocomplete || '') + ' ' + (e.name || '') + ' ' + (e.id || '') + ' ' + (e.type || '')).toLowerCase();
    return t === 'email' || /user|email|login|account|phone|identifier/.test(hint);
  }
  function step(){
    tries++;
    var pw = null;
    var pws = document.querySelectorAll('input[type=password]');
    for (var i = 0; i < pws.length; i++) if (visible(pws[i]) && !pws[i].disabled) { pw = pws[i]; break; }
    var done = false;
    if (pw) {
      var scope = pw.form || document;
      var list = scope.querySelectorAll('input');
      var user = null;
      for (var j = 0; j < list.length; j++) {
        var e = list[j];
        if (e === pw) break;
        var t = (e.type || 'text').toLowerCase();
        if (TEXTY.indexOf(t) >= 0 && visible(e) && !e.readOnly && !e.disabled) user = e;
      }
      if (user && c.u && !user.value && !user.__omniFilled) { setVal(user, c.u); user.__omniFilled = true; }
      if (!pw.value && !pw.__omniFilled) { setVal(pw, c.p); pw.__omniFilled = true; }
      done = true;
    } else if (c.u) {
      var all = document.querySelectorAll('input');
      for (var k = 0; k < all.length; k++) {
        var f = all[k];
        var ft = (f.type || 'text').toLowerCase();
        if (TEXTY.indexOf(ft) >= 0 && visible(f) && !f.readOnly && !f.disabled && looksLikeUser(f)) {
          if (!f.value && !f.__omniFilled) { setVal(f, c.u); f.__omniFilled = true; }
          break;
        }
      }
    }
    if (!done && tries < 40) setTimeout(step, 500);
  }
  step();
})($json);
''';
