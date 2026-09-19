// Reports a fresh server process, not the memory of the test runner/browser.
import {fork, execFileSync} from 'node:child_process';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createApp} from './server.mjs';
const password = 'temporary-measurement-password';
const wait = ms => new Promise(r => setTimeout(r,ms));
if (process.argv[2] === '--child') {
  const app = await createApp({root:process.argv[3],password});
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
  process.send({ready:true,port:app.server.address().port});
  process.on('message',async message=>{
    if(message==='sample'){ global.gc?.(); process.send({sample:true,...process.memoryUsage(),pid:process.pid}); }
    if(message==='close'){ await app.close(); process.disconnect(); }
  });
} else {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'lite-measure-'));
  let child;
  try {
    await fs.writeFile(path.join(root,'sample.js'),'const sample = "hello";\n'.repeat(4500));
    execFileSync('git',['init','-b','main'],{cwd:root,stdio:'ignore',windowsHide:true});
    const readyPromise=new Promise((resolve,reject)=>{
      child=fork(fileURLToPath(import.meta.url),['--child',root],{execArgv:['--expose-gc'],stdio:['ignore','inherit','inherit','ipc']});
      child.once('message',resolve);child.once('error',reject);
    });
    const ready=await readyPromise, origin=`http://127.0.0.1:${ready.port}`;
    const sample=()=>new Promise(resolve=>{child.once('message',resolve);child.send('sample');});
    await wait(200); const idle=await sample();
    let r=await fetch(origin+'/api/login',{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:JSON.stringify({password})});
    if(!r.ok) throw Error('Measurement login failed');
    const cookie=r.headers.get('set-cookie').split(';')[0]; await r.json();
    for(let i=0;i<20;i++){
      r=await fetch(origin+'/api/file?path=sample.js',{headers:{Cookie:cookie}});if(!r.ok)throw Error('Read failed');await r.json();
      r=await fetch(origin+'/api/git/status',{headers:{Cookie:cookie}});if(!r.ok)throw Error('Git failed');await r.json();
    }
    await wait(200); const afterWork=await sample();
    console.log(JSON.stringify({platform:process.platform,node:process.version,units:'bytes',forcedGC:true,scenario:'fresh server; then login + 20 reads of 103500-byte file + 20 real Git status requests',idle,afterWork,notes:'RSS is this Node process only; transient Git/credential processes and browser memory are excluded. No original VS Code baseline is available.'},null,2));
  } finally {
    if(child?.connected){const closed=new Promise(r=>child.once('exit',r));child.send('close');await closed;}
    await fs.rm(root,{recursive:true,force:true});
  }
}
