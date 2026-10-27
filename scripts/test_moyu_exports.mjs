import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const text=readFileSync(new URL('../lib/features/cinema/cinema_moyu_exports.dart',import.meta.url),'utf8');
const script=text.match(/const cinemaMoyuExportBridge = r'''([\s\S]*?)''';/)[1];
function host({origin='https://1in8b.life',active=true,size=3}={}) {
 const state={calls:[],alerts:[],prevented:0};
 const context={location:{origin},navigator:{userActivation:{isActive:active}},
  document:{addEventListener:(event,handler)=>state.click=handler},
  fetch:async()=>({blob:async()=>({size})}),
  FileReader:class { readAsDataURL(){this.result='data:image/png;base64,AQID';queueMicrotask(()=>this.onload());}},
  window:{alert:value=>state.alerts.push(value),flutter_inappwebview:{callHandler:async(...args)=>{state.calls.push(args);return true;}}},
 };
 vm.runInNewContext(script,context);
 state.event=(href='blob:https://1in8b.life/card')=>({target:{closest:()=>({href,download:'人生卡.png'})},preventDefault:()=>state.prevented++});
 return state;
}
const ok=host();await ok.click(ok.event());assert.equal(ok.prevented,1);assert.equal(ok.calls.length,1);assert.deepEqual(ok.calls[0],['nakuMoyuExport','人生卡.png','data:image/png;base64,AQID']);
const outside=host({origin:'https://example.com'});assert.equal(outside.click,undefined);
const foreign=host();await foreign.click(foreign.event('blob:https://example.com/card'));assert.equal(foreign.calls.length,0);assert.equal(foreign.prevented,0);
const inactive=host({active:false});await inactive.click(inactive.event());assert.equal(inactive.calls.length,0);
const large=host({size:65*1024*1024});await large.click(large.event());assert.equal(large.calls.length,0);assert.equal(large.alerts.length,1);
const overlap=host();await Promise.all([overlap.click(overlap.event()),overlap.click(overlap.event())]);assert.equal(overlap.calls.length,1);
console.log('6 export bridge contracts passed: real script, origin, user gesture, size limit and single-flight');
