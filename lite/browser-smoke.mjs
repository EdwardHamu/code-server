// Dependency-free CDP smoke test. BROWSER can point to Edge or Chromium.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createApp} from './server.mjs';
const candidates=[process.env.BROWSER,'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe','C:/Program Files/Microsoft/Edge/Application/msedge.exe','/usr/bin/chromium','/usr/bin/google-chrome'].filter(Boolean);
let browserPath;
for(const p of candidates)try{await fs.access(p);browserPath=p;break;}catch{}
if(!browserPath)throw Error('Set BROWSER to an installed Edge/Chromium executable. No browser is downloaded automatically.');
const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'lite-browser-')), root=path.join(tmp,'work');
await fs.mkdir(root);
await fs.writeFile(path.join(root,'sample.js'),'const greeting = "hello";\n');
await fs.writeFile(path.join(root,'large.js'),'const sample = "hello";\n'.repeat(4500));
execFileSync('git',['init','-b','main'],{cwd:root,stdio:'ignore',windowsHide:true});
execFileSync('git',['config','user.name','Browser Test'],{cwd:root,windowsHide:true});
execFileSync('git',['config','user.email','browser@example.invalid'],{cwd:root,windowsHide:true});
const password='temporary-browser-password';
const app=await createApp({root,password});await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
const url=`http://127.0.0.1:${app.server.address().port}/`;
let browser, socket, serial=0, session;
const pending=new Map(), errors=[];
const wait=ms=>new Promise(r=>setTimeout(r,ms));
function send(method,params={},sid=session){return new Promise((resolve,reject)=>{const id=++serial;const timer=setTimeout(()=>{pending.delete(id);reject(Error('CDP timeout: '+method));},20000);pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({id,method,params,...(sid?{sessionId:sid}:{})}));});}
async function evaluate(expression){const r=await send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.exception?.description||r.exceptionDetails.text);return r.result.value;}
async function until(expression){for(let i=0;i<100;i++){if(await evaluate(expression))return;await wait(50);}throw Error('Browser condition timed out: '+expression);}
try{
 const ws=await new Promise((resolve,reject)=>{
   browser=spawn(browserPath,['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--remote-debugging-port=0','--user-data-dir='+path.join(tmp,'profile'),...(process.platform==='linux'?['--no-sandbox']:[]),'about:blank'],{stdio:['ignore','ignore','pipe'],windowsHide:true});
   const timer=setTimeout(()=>reject(Error('Browser startup timeout')),20000);
   browser.on('error',e=>{clearTimeout(timer);reject(e);});
   let log='';browser.stderr.on('data',b=>{log=(log+b).slice(-16000);const match=log.match(/DevTools listening on (ws:\/\/[^\s]+)/);if(match){clearTimeout(timer);resolve(match[1]);}});
 });
 socket=new WebSocket(ws);await new Promise((r,j)=>{socket.onopen=r;socket.onerror=j;});
 socket.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(m.error.message)):p.resolve(m.result);}else if(m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails.text);};
 const target=await send('Target.createTarget',{url:'about:blank'},null);
 session=(await send('Target.attachToTarget',{targetId:target.targetId,flatten:true},null)).sessionId;
 await send('Runtime.enable');await send('Page.enable');await send('Performance.enable');
 await send('Emulation.setDeviceMetricsOverride',{width:1280,height:800,deviceScaleFactor:1,mobile:false});
 await send('Page.navigate',{url});await until('document.readyState === "complete" && typeof state !== "undefined"');
 assert.equal(await evaluate('document.getElementById("login-overlay").hidden'),false);
 await evaluate(`document.getElementById('password').value=${JSON.stringify(password)};document.getElementById('login-form').requestSubmit()`);
 await until('state.csrf.length > 0 && document.querySelectorAll(".tree-button").length === 2');
 await send('HeapProfiler.collectGarbage');const idle=await send('Performance.getMetrics');
 await evaluate('openFile("sample.js")');assert.equal(await evaluate('code.value'),'const greeting = "hello";\n');
 await evaluate('code.focus();code.select()');
 await send('Input.insertText',{text:'const greeting = "edited";\n'});
 await send('Input.dispatchKeyEvent',{type:'keyDown',key:'s',code:'KeyS',modifiers:2,windowsVirtualKeyCode:83});
 await send('Input.dispatchKeyEvent',{type:'keyUp',key:'s',code:'KeyS',modifiers:2,windowsVirtualKeyCode:83});
 await until('!state.dirty && !state.busy');assert.equal(await fs.readFile(path.join(root,'sample.js'),'utf8'),'const greeting = "edited";\n');
 await evaluate('code.value = "<img src=x onerror=alert(1)>";render()');
 assert.equal(await evaluate('document.querySelectorAll("#colored img").length'),0);
 await evaluate('state.dirty=false;openFile("large.js")');
 for(let i=0;i<10;i++)await evaluate('state.dirty=false;openFile("sample.js").then(()=>openFile("large.js"))');
 await evaluate('code.scrollTop=2100;renderViewport(true)');
 assert.equal(await evaluate('document.getElementById("gutter-lines").textContent.split("\\n")[0]'),'101');
 assert.ok(await evaluate('document.querySelectorAll("#colored span").length < 1000'));
 await evaluate('selectTab(true);refreshGit()');
 assert.ok(await evaluate('document.querySelectorAll(".change").length >= 1'));
 await send('HeapProfiler.collectGarbage');const loaded=await send('Performance.getMetrics');
 assert.deepEqual(errors,[]);
 if(process.env.SCREENSHOT){const shot=await send('Page.captureScreenshot',{format:'png'});await fs.writeFile(process.env.SCREENSHOT,Buffer.from(shot.data,'base64'));}
 const heap=m=>Object.fromEntries(m.metrics.filter(x=>['JSHeapUsedSize','JSHeapTotalSize','Nodes','Documents','JSEventListeners'].includes(x.name)).map(x=>[x.name,x.value]));
 console.log(JSON.stringify({browser:browserPath,checks:'login, file listing, native input + Ctrl-S save to real disk, escaped highlighting, repeated file switches, viewport-bounded highlight nodes and line numbers, Git status, no uncaught exceptions',idle:heap(idle),afterRepeatedOpen:heap(loaded),notes:'Browser renderer JS heap after forced GC, NOT total browser RAM; synthetic fixture only.'},null,2));
}catch(e){console.error(e);process.exitCode=1;}
finally{
 if(socket?.readyState===1){try{await send('Browser.close',{},null);}catch{}socket.close();}
 if(browser&&browser.exitCode===null){await Promise.race([new Promise(r=>browser.once('exit',r)),wait(5000)]);if(browser.exitCode===null)browser.kill();}
 for(const p of pending.values())clearTimeout(p.timer);
 await app.close();await fs.rm(tmp,{recursive:true,force:true,maxRetries:6,retryDelay:500});
}
