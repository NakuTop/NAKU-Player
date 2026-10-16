import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_webview_media.dart';

void main() {
  test(
    'video window restores styles and validates iframe message sources',
    () async {
      final scripts = jsonEncode({
        'install': cinemaWebVideoPipScript,
        'pip': cinemaWebVideoAction('pip'),
        'back': cinemaWebVideoAction('back'),
      });
      final result = await Process.run('node', [
        '-e',
        r'''
const vm=require('node:vm');const assert=require('node:assert/strict');
const scripts=JSON.parse(process.argv[1]);const handlers={};const messages=[];const ids={};
function element(tag){const attributes={};return {tagName:tag,children:[],parentElement:null,style:{setProperty(k,v){attributes.style=(attributes.style||'')+k+':'+v+';';}},getAttribute:k=>attributes[k]??null,setAttribute(k,v){attributes[k]=v;},removeAttribute(k){delete attributes[k];},appendChild(e){e.parentElement=this;this.children.push(e);if(e.id)ids[e.id]=e;},addEventListener(name,fn){this[name]=fn;},remove(){if(this.parentElement)this.parentElement.children=this.parentElement.children.filter(x=>x!==this);delete ids[this.id];}};}
const html=element('HTML'),body=element('BODY'),v=element('VIDEO'),nav=element('NAV'),frame=element('IFRAME');html.appendChild(body);body.appendChild(nav);body.appendChild(v);body.appendChild(frame);v.setAttribute('style','width:400px');
Object.assign(v,{paused:false,currentTime:20,disablePictureInPicture:false,webkitPresentationMode:'inline',webkitSupportsPresentationMode:()=>false});
const childMessages=[];frame.contentWindow={postMessage:m=>childMessages.push(m)};
const document={documentElement:html,body,pictureInPictureEnabled:true,querySelectorAll:q=>q==='iframe'?[frame]:[v],querySelector:()=>v,addEventListener:(name,fn)=>{handlers[name]=fn;},getElementById:id=>ids[id]||null,createElement:tag=>element(tag.toUpperCase())};
const window={addEventListener:(name,fn)=>{handlers['window:'+name]=fn;},flutter_inappwebview:{callHandler:(name,action)=>messages.push({name,action})}};window.top=window;document.defaultView=window;
const context=vm.createContext({window,document});vm.runInContext(scripts.install,context);handlers.loadedmetadata();
assert.equal(ids['naku-video-only-pip'].textContent,'视频浮窗');ids['naku-video-only-pip'].click({stopPropagation(){}});
assert.equal(messages.at(-1).action,'enter');assert.match(v.getAttribute('style'),/position:fixed/);assert.match(nav.getAttribute('style'),/visibility:hidden/);
window.__nakuExitVideoWindow();assert.equal(v.getAttribute('style'),'width:400px');assert.equal(nav.getAttribute('style'),null);
const before=messages.length;handlers['window:message']({data:{channel:'naku-video-window-v1',action:'enter'},source:{}});assert.equal(messages.length,before);
handlers['window:message']({data:{channel:'naku-video-window-v1',action:'enter',code:'evil'},source:frame.contentWindow});assert.equal(messages.length,before);
handlers['window:message']({data:{channel:'naku-video-window-v1',action:'enter'},source:frame.contentWindow});assert.equal(messages.at(-1).action,'enter');assert.match(frame.getAttribute('style'),/position:fixed/);
window.__nakuExitVideoWindow();assert.equal(childMessages.at(-1).action,'restore');assert.equal(frame.getAttribute('style'),null);
v.webkitSupportsPresentationMode=()=>true;v.webkitSetPresentationMode=mode=>v.webkitPresentationMode=mode;
assert.equal(vm.runInContext(scripts.pip,context),'started');assert.equal(v.webkitPresentationMode,'picture-in-picture');vm.runInContext(scripts.back,context);assert.equal(v.currentTime,10);

''',
        scripts,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout} ${result.stderr}');
      expect(() => cinemaWebVideoAction('pip;alert(1)'), throwsArgumentError);
    },
  );

  test(
    'hidden documents stay suspended after a new page commits; show never plays',
    () async {
      final calls = <String>[];
      final media = CinemaWebMediaLifecycle(
        pause: () async {
          calls.add('pause');
        },
        suspend: (value) async {
          calls.add('suspend:$value');
        },
      );
      await media.setHidden(true);
      await media.documentReady();
      expect(calls, ['pause', 'suspend:true', 'pause', 'suspend:true']);
      calls.clear();
      await media.setHidden(false);
      expect(calls, ['pause', 'suspend:false']);
      calls.clear();
      await media.documentReady();
      expect(calls, isEmpty);
    },
  );

  test(
    'leaving while native pause is pending ends suspended, not resumed',
    () async {
      final gate = Completer<void>();
      final calls = <bool>[];
      var first = true;
      final media = CinemaWebMediaLifecycle(
        pause: () async {
          if (first) {
            first = false;
            await gate.future;
          }
        },
        suspend: (value) async {
          calls.add(value);
        },
      );
      final shown = media.setHidden(false);
      final closed = media.close();
      gate.complete();
      await shown;
      await closed;
      await media.setHidden(false);
      expect(calls, isNotEmpty);
      expect(calls.every((value) => value), isTrue);
    },
  );

  test(
    'unsupported media API does not prevent close or remaining state updates',
    () async {
      final suspended = <bool>[];
      final media = CinemaWebMediaLifecycle(
        pause: () async {
          throw UnsupportedError('legacy engine');
        },
        suspend: (value) async {
          suspended.add(value);
        },
      );
      await media.setHidden(true);
      await media.close();
      expect(suspended, [true, true]);
    },
  );

  test('track commands reject code strings and excessive indexes', () {
    expect(
      () => cinemaWebMediaTrackAction('audio;alert(1)', 0),
      throwsArgumentError,
    );
    expect(
      () => cinemaWebMediaTrackAction('subtitle', 129),
      throwsArgumentError,
    );
    expect(() => cinemaWebMediaTrackAction('audio', -2), throwsArgumentError);
  });
}
