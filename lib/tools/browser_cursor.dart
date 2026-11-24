/// A visible mouse cursor drawn inside the page while the assistant uses the built-in browser: it glides to
/// the element, pulses with a ripple and a glowing outline when it presses, and types letter by letter.
/// It lives in the page itself (a fixed, click-through layer on the root element) so it lines up with the
/// real element positions. Built with DOM calls only (no innerHTML / inline-style markup), so pages with a
/// strict Content-Security-Policy cannot block it. Calling the script twice is harmless.
const String omniCursorScript = r'''
(function(){
 if(window.__omniCursor&&document.getElementById('__omni_cursor'))return;
 var NS='http://www.w3.org/2000/svg';
 var root=document.createElement('div');root.id='__omni_cursor';
 root.style.cssText='all:initial;position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;';
 var cur=document.createElement('div');
 cur.style.cssText='position:fixed;left:0;top:0;opacity:0;transform:translate(-80px,-80px);will-change:transform;pointer-events:none;transition:transform 300ms cubic-bezier(.22,1,.36,1),opacity 250ms;';
 var svg=document.createElementNS(NS,'svg');svg.setAttribute('width','28');svg.setAttribute('height','28');svg.setAttribute('viewBox','0 0 24 24');
 svg.style.cssText='display:block;overflow:visible;filter:drop-shadow(0 0 7px rgba(59,130,246,.95)) drop-shadow(0 1px 2px rgba(0,0,0,.55));';
 var path=document.createElementNS(NS,'path');path.setAttribute('d','M4 2l15 9-6.5 1.6L9.5 19z');path.setAttribute('fill','#ffffff');
 path.setAttribute('stroke','#0b1220');path.setAttribute('stroke-width','1.4');path.setAttribute('stroke-linejoin','round');svg.appendChild(path);
 var chip=document.createElement('span');
 chip.style.cssText='position:absolute;left:22px;top:20px;padding:3px 8px;border-radius:9px;font:600 11px/1.2 system-ui,sans-serif;color:#fff;background:rgba(20,40,90,.88);border:1px solid rgba(96,165,250,.6);white-space:nowrap;opacity:0;transition:opacity 200ms;box-shadow:0 0 10px rgba(59,130,246,.45);';
 cur.appendChild(svg);cur.appendChild(chip);root.appendChild(cur);
 var timer=null,x=0,y=0;
 function mount(){if(!root.isConnected)(document.documentElement||document.body).appendChild(root);}
 function idle(){clearTimeout(timer);timer=setTimeout(function(){cur.style.opacity='0';chip.style.opacity='0';},3500);}
 function say(t){if(t){chip.textContent=t;chip.style.opacity='1';}else{chip.style.opacity='0';}}
 function place(px,py,ms){mount();cur.style.transitionDuration=(ms===0?'0ms':(ms||300)+'ms')+',250ms';cur.style.opacity='1';x=px;y=py;cur.style.transform='translate('+(px-3)+'px,'+(py-2)+'px)';idle();}
 function point(el){var r=el.getBoundingClientRect();return {x:Math.max(4,Math.min(innerWidth-4,r.left+r.width/2)),y:Math.max(4,Math.min(innerHeight-4,r.top+r.height/2)),r:r};}
 function ring(r){
  mount();var d=document.createElement('div');
  d.style.cssText='position:fixed;pointer-events:none;border:2px solid #60a5fa;border-radius:8px;box-shadow:0 0 14px rgba(59,130,246,.85),inset 0 0 8px rgba(59,130,246,.35);left:'+(r.left-3)+'px;top:'+(r.top-3)+'px;width:'+(r.width+6)+'px;height:'+(r.height+6)+'px;opacity:0;';
  root.appendChild(d);
  try{d.animate([{opacity:0},{opacity:1,offset:.25},{opacity:0}],{duration:1100,easing:'ease-out'}).onfinish=function(){d.remove();};}catch(e){setTimeout(function(){d.remove();},1100);}
 }
 function ripple(px,py){
  mount();var d=document.createElement('div');
  d.style.cssText='position:fixed;pointer-events:none;width:14px;height:14px;margin:-7px 0 0 -7px;border-radius:50%;border:2px solid #60a5fa;background:rgba(96,165,250,.25);left:'+px+'px;top:'+py+'px;';
  root.appendChild(d);
  try{d.animate([{transform:'scale(.4)',opacity:.95},{transform:'scale(3.2)',opacity:0}],{duration:560,easing:'ease-out'}).onfinish=function(){d.remove();};}catch(e){setTimeout(function(){d.remove();},560);}
  try{svg.animate([{transform:'scale(1)'},{transform:'scale(.82)',offset:.35},{transform:'scale(1)'}],{duration:260,easing:'ease-out'});}catch(e){}
 }
 function setValue(e,v){
  if(e.isContentEditable){e.textContent=v;return;}
  var proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
  var d=Object.getOwnPropertyDescriptor(proto,'value');
  if(d&&d.set){d.set.call(e,v);}else{e.value=v;}
  e.dispatchEvent(new Event('input',{bubbles:true}));
 }
 window.__omniCursor={
  // Glide to an element (and outline it). The caller waits for the glide before acting.
  go:function(el,label){var p=point(el);place(p.x,p.y,300);ring(p.r);say(label||'');return p;},
  // The press: a ripple at the cursor.
  press:function(){ripple(x,y);},
  // Types the text letter by letter into the field; returns the time it will take.
  typeInto:function(el,text,maxMs){
   var n=text.length,steps=Math.min(n,40),per=Math.max(25,Math.min(70,(maxMs||1400)/Math.max(steps,1)));
   var i=0;try{el.focus();}catch(e){}
   say('Typing…');
   var iv=setInterval(function(){
    i++;var upto=Math.ceil(n*i/steps);try{setValue(el,text.slice(0,upto));}catch(e){}
    if(i>=steps){clearInterval(iv);say('');}
   },per);
   return Math.round(steps*per);
  },
  // Glide to a spot over `ms` (used while dragging).
  move:function(px,py,ms,label){place(px,py,ms);say(label||'');}
 };
})();
''';
