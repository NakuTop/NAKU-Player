import 'dart:async';

/// Serializes native WebKit media state changes, including delayed creation.
/// Releasing suspension never asks the document to play.
class CinemaWebMediaLifecycle {
  CinemaWebMediaLifecycle({required this.pause, required this.suspend});
  final Future<void> Function() pause;
  final Future<void> Function(bool) suspend;
  Future<void> _pending = Future.value();
  bool _blocked = false;
  bool _closed = false;

  Future<void> setHidden(bool blocked) {
    if (_closed || (!blocked && !_blocked)) return _pending;
    _blocked = blocked;
    return _enqueue(() async {
      await _try(pause);
      await _try(() => suspend(_blocked));
    });
  }

  Future<void> documentReady() {
    if (_closed) return _pending;
    return _enqueue(() async {
      if (_blocked || _closed) {
        await _try(pause);
        await _try(() => suspend(true));
      }
    });
  }

  Future<void> close() {
    _closed = true;
    _blocked = true;
    return _enqueue(() async {
      await _try(pause);
      await _try(() => suspend(true));
    });
  }

  Future<void> _enqueue(Future<void> Function() action) =>
      _pending = _pending.then((_) => action());
  Future<void> _try(Future<void> Function() action) async {
    try {
      await action().timeout(const Duration(seconds: 2));
    } catch (_) {
      /* Unsupported older web engines. */
    }
  }
}

// Deliberately only inspects same-origin documents. Cross-origin players keep
// their own controls. No website-supplied JavaScript or URLs are evaluated.
const cinemaWebMediaInspection = r'''
(() => {
 const videos=[];
 function scan(doc) {
   for(const v of doc.querySelectorAll('video,audio')) videos.push(v);
   for(const f of doc.querySelectorAll('iframe')) { try { if(f.contentDocument) scan(f.contentDocument); } catch(_) {} }
 }
 scan(document);
 const v=videos.find(v=>!v.paused)||videos[0];
 if(!v) return null;
 v.controls=true;
 const list=(xs)=>Array.from(xs||[]).map((t,i)=>({index:i,label:String(t.label||t.language||('轨道 '+(i+1))).slice(0,120)}));
 return {audio:list(v.audioTracks),subtitles:list(v.textTracks),quality:[]};
})()
''';

String cinemaWebMediaTrackAction(String kind, int index) {
  if (!const ['audio', 'subtitle'].contains(kind) ||
      index < -1 ||
      index > 128) {
    throw ArgumentError('Invalid media track');
  }
  return '''(() => {
const videos=[];
function scan(d){for(const v of d.querySelectorAll('video,audio'))videos.push(v);for(const f of d.querySelectorAll('iframe')){try{if(f.contentDocument)scan(f.contentDocument);}catch(_){}}}
scan(document);const v=videos.find(v=>!v.paused)||videos[0];if(!v)return false;
const ts=v.${kind == 'audio' ? 'audioTracks' : 'textTracks'};if(!ts||$index>=ts.length)return false;
for(let i=0;i<ts.length;i++){${kind == 'audio' ? 'ts[i].enabled=(i===$index)' : "ts[i].mode=i===$index?'showing':'disabled'"};}return true;
})()''';
}

// Executed in each document, including cross-origin frames by WKUserScript.
// A real click inside that frame supplies the browser's required user gesture.
// A fixed enter/exit bridge changes UI only; parent messages must originate
// from a directly embedded iframe. No arbitrary code or URL bridge is exposed.
const cinemaWebVideoPipScript = r'''
(() => {
 if(window.__nakuVideoPipInstalled)return;
 window.__nakuVideoPipInstalled=true;
 const channel='naku-video-window-v1';
 let saved=[],focused=null,child=null,exitButton=null;
 function nativeSupported(v){if(v.disablePictureInPicture)return false;if(typeof v.webkitSupportsPresentationMode==='function')return v.webkitSupportsPresentationMode('picture-in-picture');return !!(document.pictureInPictureEnabled&&typeof v.requestPictureInPicture==='function');}
 function remember(el){if(!saved.some(x=>x.el===el))saved.push({el,style:el.getAttribute('style')});}
 function style(el,values){remember(el);for(const [k,v]of Object.entries(values))el.style.setProperty(k,v,'important');}
 function notify(action){if(window===window.top){const bridge=window.flutter_inappwebview;if(bridge&&typeof bridge.callHandler==='function')bridge.callHandler('nakuVideoWindow',action);}else window.parent.postMessage({channel,action},'*');}
 function focus(el){
   if(focused===el)return;
   restore(true);
   focused=el;
   let node=el;
   while(node&&node.parentElement){
     for(const sibling of node.parentElement.children)if(sibling!==node)style(sibling,{visibility:'hidden','pointer-events':'none'});
     node=node.parentElement;style(node,{transform:'none',filter:'none',perspective:'none',contain:'none',overflow:'visible',margin:'0',padding:'0',background:'#000'});
   }
   style(document.documentElement,{overflow:'hidden',background:'#000'});
   if(document.body)style(document.body,{overflow:'hidden',background:'#000'});
   style(el,{position:'fixed',inset:'0',width:'100vw',height:'100vh','max-width':'none','max-height':'none',margin:'0',padding:'0',border:'0',visibility:'visible','z-index':'2147483645','object-fit':'contain',background:'#000','pointer-events':'auto'});
   const launch=document.getElementById('naku-video-only-pip');if(launch)style(launch,{display:'none'});
   if(el.tagName==='VIDEO'){
     exitButton=document.createElement('button');exitButton.type='button';exitButton.textContent='退出视频浮窗';exitButton.setAttribute('aria-label','退出视频浮窗');
     exitButton.style.cssText='position:fixed;right:8px;top:8px;z-index:2147483647;padding:6px;background:#222b;color:white;border:0;border-radius:5px;cursor:pointer';
     exitButton.onclick=()=>{restore(true);notify('exit');};(document.body||document.documentElement).appendChild(exitButton);
   }
 }
 function restore(propagate){
   const oldChild=child;child=null;
   if(propagate&&oldChild)oldChild.postMessage({channel,action:'restore'},'*');
   if(exitButton){exitButton.remove();exitButton=null;}
   for(const {el,style}of saved){if(style===null)el.removeAttribute('style');else el.setAttribute('style',style);}
   saved=[];focused=null;
 }
 function fallback(v){focus(v);notify('enter');return true;}
 function enter(v){
   if(!nativeSupported(v))return fallback(v);
   try{
     if(typeof v.webkitSetPresentationMode==='function'&&typeof v.webkitSupportsPresentationMode==='function'&&v.webkitSupportsPresentationMode('picture-in-picture')){
       v.webkitSetPresentationMode(v.webkitPresentationMode==='picture-in-picture'?'inline':'picture-in-picture');return true;
     }
     const p=document.pictureInPictureElement?document.exitPictureInPicture():v.requestPictureInPicture();
     if(p&&typeof p.catch==='function')p.catch(()=>fallback(v));return true;
   }catch(_){return fallback(v);}
 }
 window.__nakuEnterVideoPip=enter;
 window.__nakuExitVideoWindow=()=>{restore(true);};
 window.addEventListener('message',event=>{
   const data=event.data;
   if(!data||typeof data!=='object'||data.channel!==channel||!['enter','exit','restore'].includes(data.action)||Object.keys(data).length!==2)return;
   if(data.action==='restore'){
     if(event.source===window.parent&&window!==window.top)restore(true);
     return;
   }
   const frame=Array.from(document.querySelectorAll('iframe')).find(f=>f.contentWindow===event.source);
   if(!frame)return;
   if(data.action==='enter'){focus(frame);child=event.source;notify('enter');}
   else if(child===event.source){restore(true);notify('exit');}
 });
 function update(){
   if(focused)return;
   const videos=Array.from(document.querySelectorAll('video'));
   const v=videos.find(v=>!v.paused)||videos[0];
   let button=document.getElementById('naku-video-only-pip');
   if(!v){if(button)button.remove();return;}
   if(!button){
     button=document.createElement('button');button.id='naku-video-only-pip';button.type='button';
     button.style.cssText='position:fixed;right:12px;bottom:64px;z-index:2147483646;padding:7px 10px;border:1px solid #aaa;border-radius:6px;background:#222;color:white;font-size:12px;cursor:pointer';
     button.addEventListener('click',(event)=>{event.stopPropagation();const current=Array.from(document.querySelectorAll('video')).find(v=>!v.paused)||document.querySelector('video');if(current)enter(current);});
     (document.body||document.documentElement).appendChild(button);
   }
   button.textContent=nativeSupported(v)?'视频画中画':'视频浮窗';button.setAttribute('aria-label',button.textContent);
 }
 document.addEventListener('loadedmetadata',update,true);
 document.addEventListener('canplay',update,true);
 document.addEventListener('play',update,true);
 document.addEventListener('DOMContentLoaded',update,{once:true});
})()
''';

String cinemaWebVideoAction(String action) {
  if (!const ['pip', 'toggle', 'back', 'forward', 'speed'].contains(action)) {
    throw ArgumentError('Invalid video action');
  }
  final operation = switch (action) {
    'pip' =>
      "if(typeof owner.__nakuEnterVideoPip==='function'&&owner.__nakuEnterVideoPip(v))return 'started';return 'unsupported';",
    'toggle' =>
      "if(v.paused){const p=v.play();if(p&&p.catch)p.catch(()=>{});}else v.pause();",
    'back' => 'v.currentTime=Math.max(0,v.currentTime-10);',
    'forward' =>
      'v.currentTime=Math.min(Number.isFinite(v.duration)?v.duration:Infinity,v.currentTime+10);',
    _ =>
      'const speeds=[1,1.25,1.5,2];v.playbackRate=speeds[(speeds.indexOf(v.playbackRate)+1)%speeds.length];',
  };
  return '''(() => {
 const entries=[];
 function scan(doc){for(const v of doc.querySelectorAll('video,audio'))entries.push({v,owner:doc.defaultView});for(const f of doc.querySelectorAll('iframe')){try{if(f.contentDocument)scan(f.contentDocument);}catch(_){}}}
 scan(document);const entry=entries.find(e=>!e.v.paused)||entries[0];if(!entry)return 'missing';const {v,owner}=entry;
 $operation
 return 'done';
})()''';
}
