import {test} from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {createApp, parseArgs} from '../server.mjs';
import {MAX_FILE} from '../files.mjs';

const password = 'test-only-password-123';
function git(root, args) { return execFileSync('git', args, {cwd:root, encoding:'utf8', windowsHide:true, env:{...process.env,GIT_TERMINAL_PROMPT:'0'}, stdio:['ignore','pipe','pipe']}); }
async function setup(t, options = {}) {
  const folder = await fs.mkdtemp(path.join(os.tmpdir(), 'code-lite-test-'));
  const root = path.join(folder,'work'); await fs.mkdir(root);
  const app = await createApp({root,password,...options});
  await new Promise(r => app.server.listen(0,'127.0.0.1',r));
  const origin = `http://127.0.0.1:${app.server.address().port}`, base = origin + (options.basePath || '');
  let cookie = '', csrf = '';
  async function request(route, data, overrides = {}) {
    const response = await fetch(base + '/api/' + route, {method:data === undefined ? 'GET' : 'POST', headers:{Cookie:cookie,Origin:options.origin || origin,'Content-Type':'application/json','X-Lite-CSRF':csrf,...overrides}, ...(data === undefined ? {} : {body:JSON.stringify(data)})});
    const json = await response.json(); return {status:response.status, json, response};
  }
  async function login() {
    const r = await request('login',{password}); assert.equal(r.status,200);
    cookie = r.response.headers.get('set-cookie').split(';')[0];
    csrf = (await request('session')).json.csrf; return r;
  }
  t.after(async () => { await app.close(); await fs.rm(folder,{recursive:true,force:true}); });
  return {root,folder,app,origin,base,request,login};
}
test('auth gates APIs, HttpOnly cookie, logout invalidates session', async t => {
  const f = await setup(t);
  assert.equal((await f.request('files')).status,401);
  assert.equal((await f.request('login',{password:'wrong'})).status,401);
  const r = await f.login(); assert.match(r.response.headers.get('set-cookie'),/HttpOnly; SameSite=Strict/);
  assert.equal((await f.request('files')).status,200);
  assert.equal((await f.request('logout',{})).status,200);
  assert.equal((await f.request('files')).status,401);
});
test('cross origin login, missing origin, missing CSRF and non-JSON are refused', async t => {
  const f = await setup(t);
  assert.equal((await f.request('login',{password},{Origin:'https://evil.test'})).status,403);
  assert.equal((await f.request('login',{password},{Origin:''})).status,403);
  await f.login();
  assert.equal((await f.request('create',{path:'bad'},{'X-Lite-CSRF':''})).status,403);
  assert.equal((await f.request('create',{path:'bad'},{Origin:'https://evil.test'})).status,403);
  assert.equal((await f.request('create',{path:'bad'},{'Content-Type':'text/plain'})).status,415);
  await assert.rejects(fs.stat(path.join(f.root,'bad')));
});
test('bounded password attempts and no password CLI argument', async t => {
  const f = await setup(t);
  for (let i=0;i<5;i++) assert.equal((await f.request('login',{password:'incorrect'})).status,401);
  assert.equal((await f.request('login',{password})).status,429);
  assert.throws(() => parseArgs(['--password','secret']),/Unsupported option/);
  assert.throws(() => parseArgs(['--host','0.0.0.0']),/requires/);
  assert.equal(parseArgs(['--host','0.0.0.0','--secure-cookie','--origin','https://editor.test']).host,'0.0.0.0');
  await assert.rejects(createApp({root:f.root,password:'short'}),/12/);
});
test('base path, HTTPS cookie and security response headers', async t => {
  const f = await setup(t,{basePath:'/code',origin:'https://editor.test',secureCookie:true});
  const r = await f.login(); assert.match(r.response.headers.get('set-cookie'),/Path=\/code\//); assert.match(r.response.headers.get('set-cookie'),/Secure/);
  const page = await fetch(f.base + '/'); assert.equal(page.status,200); assert.match(page.headers.get('content-security-policy'),/frame-ancestors 'none'/);
  assert.equal((await fetch(f.origin + '/api/files')).status,404);
});
test('file creation, lazy listing, UTF-8 BOM/CRLF save and stale-save protection', async t => {
  const f = await setup(t); await f.login();
  assert.equal((await f.request('create',{path:'folder',directory:true})).status,200);
  assert.equal((await f.request('create',{path:'folder/空 格.js'})).status,200);
  const file = path.join(f.root,'folder','空 格.js'); await fs.writeFile(file,'\uFEFFconst a = 1;\r\n');
  const listing = await f.request('files'); assert.equal(listing.json.entries[0].name,'folder'); assert.equal(listing.json.entries[0].children,undefined);
  const read = await f.request('file?path='+encodeURIComponent('folder/空 格.js')); assert.equal(read.json.bom,true); assert.equal(read.json.newline,'\r\n');
  const save = await f.request('save',{...read.json,content:'const a = 2;\n'}); assert.equal(save.status,200);
  assert.equal(await fs.readFile(file,'utf8'),'\uFEFFconst a = 2;\r\n');
  assert.equal((await f.request('save',{...read.json,content:'stale'})).status,409);
  assert.equal((await f.request('create',{path:'folder/空 格.js'})).status,409);
  const latest = await f.request('file?path='+encodeURIComponent('folder/空 格.js'));
  assert.equal((await f.request('delete',{path:latest.json.path,version:latest.json.version})).status,200);
  assert.equal((await f.request('file?path='+encodeURIComponent('folder/空 格.js'))).status,404);
});
test('path traversal, absolute paths, Git metadata, ADS and special names are blocked', async t => {
  const f = await setup(t); await f.login(); await fs.mkdir(path.join(f.root,'.git'));
  await fs.writeFile(path.join(f.folder,'secret'),'outside');
  for (const name of ['../secret','/secret','C:/secret','folder/../../secret','.git/config','.GIT/config','a\\..\\secret','file:stream','con','bad.']) {
    assert.equal((await f.request('file?path='+encodeURIComponent(name))).status,400,name);
    assert.equal((await f.request('create',{path:name})).status,400,name);
  }
  assert.equal((await f.request('files')).json.entries.some(e=>e.name==='.git'),false);
});
test('external junction/symlink and hardlink are not served', async t => {
  const f = await setup(t); await f.login();
  const outside=path.join(f.folder,'outside'); await fs.mkdir(outside); await fs.writeFile(path.join(outside,'secret.txt'),'secret');
  await fs.symlink(outside,path.join(f.root,'linked'),process.platform==='win32'?'junction':'dir');
  assert.equal((await f.request('file?path=linked/secret.txt')).status,403);
  assert.equal((await f.request('create',{path:'linked/new.txt'})).status,403);
  await fs.link(path.join(outside,'secret.txt'),path.join(f.root,'hard.txt'));
  assert.equal((await f.request('file?path=hard.txt')).status,403);
});
test('binary, invalid UTF-8 and oversized files cannot be edited', async t => {
  const f=await setup(t); await f.login();
  await fs.writeFile(path.join(f.root,'binary'),Buffer.from([0,1,2]));
  await fs.writeFile(path.join(f.root,'invalid'),Buffer.from([255,254,255]));
  await fs.writeFile(path.join(f.root,'large'),Buffer.alloc(MAX_FILE+1,65));
  assert.equal((await f.request('file?path=binary')).status,415);
  assert.equal((await f.request('file?path=invalid')).status,415);
  assert.equal((await f.request('file?path=large')).status,413);
});
test('directory enumeration is bounded', async t => {
  const f=await setup(t); await f.login();
  for(let start=0;start<1002;start+=100) await Promise.all(Array.from({length:Math.min(100,1002-start)},(_,i)=>fs.writeFile(path.join(f.root,'f'+(start+i)),'')));
  const r=await f.request('files'); assert.equal(r.json.entries.length,1000); assert.equal(r.json.truncated,true);
});
async function init(f) {
  git(f.root,['init','-b','main']); git(f.root,['config','user.name','Lite Test']); git(f.root,['config','user.email','lite@example.invalid']);
  await fs.writeFile(path.join(f.root,'a.txt'),'first\n'); git(f.root,['add','a.txt']); git(f.root,['commit','-m','initial']);
}
test('real Git status, worktree/cached diff, literal paths, stage/unstage and commit', async t => {
  const f=await setup(t); await f.login(); await init(f);
  await fs.writeFile(path.join(f.root,'a.txt'),'changed\n'); await fs.mkdir(path.join(f.root,'new dir')); await fs.writeFile(path.join(f.root,'new dir','汉 字.txt'),'new');
  let r=await f.request('git/status'); assert.equal(r.json.branch,'main'); assert.ok(r.json.files.some(x=>x.path==='new dir'));
  assert.match((await f.request('git/diff?path=a.txt')).json.text,/\+changed/);
  assert.equal((await f.request('git/action',{action:'stage',path:'new dir'})).status,200);
  assert.equal((await f.request('git/action',{action:'stage',path:'a.txt'})).status,200);
  assert.match((await f.request('git/diff?path=a.txt&staged=1')).json.text,/\+changed/);
  assert.equal((await f.request('git/action',{action:'unstage',path:'a.txt'})).status,200);
  assert.equal((await f.request('git/action',{action:'stage',path:'a.txt'})).status,200);
  assert.equal((await f.request('git/action',{action:'commit',message:'from lite'})).status,200);
  assert.equal(git(f.root,['log','-1','--format=%s']).trim(),'from lite'); assert.equal((await f.request('git/status')).json.files.length,0);
});
test('unborn repository can stage and unstage without losing working files', async t => {
  const f=await setup(t); await f.login(); git(f.root,['init','-b','main']); await fs.writeFile(path.join(f.root,'first.txt'),'keep');
  assert.equal((await f.request('git/action',{action:'stage',path:'first.txt'})).status,200);
  assert.equal((await f.request('git/action',{action:'unstage',path:'first.txt'})).status,200);
  assert.equal(await fs.readFile(path.join(f.root,'first.txt'),'utf8'),'keep');
});
test('branch creation/switch rejects dirty trees and invalid/injected arguments', async t => {
  const f=await setup(t); await f.login(); await init(f);
  assert.equal((await f.request('git/action',{action:'branch',branch:'feature/lite'})).status,200);
  assert.equal((await f.request('git/action',{action:'switch',branch:'main'})).status,200);
  await fs.writeFile(path.join(f.root,'a.txt'),'dirty');
  assert.equal((await f.request('git/action',{action:'switch',branch:'feature/lite'})).status,409);
  assert.equal((await f.request('git/action',{action:'branch',branch:'--help'})).status,400);
  assert.equal((await f.request('git/action',{action:'stage',path:':(glob)*'})).status,400);
  assert.equal((await f.request('git/action',{action:'shell',message:'echo bad'})).status,400);
});
test('Git does not discover a parent repository or accept external gitdir', async t => {
  const f=await setup(t); await f.login(); git(f.folder,['init','-b','main']);
  assert.equal((await f.request('git/status')).status,400);
  await fs.writeFile(path.join(f.root,'.git'),'gitdir: ../.git\n');
  assert.equal((await f.request('git/status')).status,403);
});
test('real local remote fetch, fast-forward pull and push, no internet', async t => {
  const f=await setup(t); await f.login(); await init(f);
  const bare=path.join(f.folder,'remote.git'), peer=path.join(f.folder,'peer');
  git(f.folder,['init','--bare',bare]); git(f.root,['remote','add','origin',bare]); git(f.root,['push','-u','origin','main']);
  git(f.folder,['clone','--branch','main',bare,peer]); git(peer,['config','user.name','Peer']); git(peer,['config','user.email','peer@example.invalid']);
  await fs.writeFile(path.join(peer,'peer.txt'),'remote'); git(peer,['add','.']); git(peer,['commit','-m','peer']); git(peer,['push']);
  assert.equal((await f.request('git/action',{action:'fetch'})).status,200);
  assert.equal((await f.request('git/action',{action:'pull'})).status,200);
  assert.equal(await fs.readFile(path.join(f.root,'peer.txt'),'utf8'),'remote');
  await fs.writeFile(path.join(f.root,'a.txt'),'push from editor');
  await f.request('git/action',{action:'stage',path:'a.txt'}); await f.request('git/action',{action:'commit',message:'push test'});
  assert.equal((await f.request('git/action',{action:'push'})).status,200);
  assert.equal(git(bare,['log','main','-1','--format=%s']).trim(),'push test');
});
test('concurrent saves cannot silently overwrite one another', async t => {
  const f=await setup(t); await f.login(); await fs.writeFile(path.join(f.root,'race.txt'),'base');
  const old=(await f.request('file?path=race.txt')).json;
  const results=await Promise.all(['one','two'].map(content=>f.request('save',{...old,content})));
  assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);
  assert.ok(['one','two'].includes(await fs.readFile(path.join(f.root,'race.txt'),'utf8')));
  assert.equal((await fs.readdir(f.root)).some(n=>n.startsWith('.lite-save-')),false);
});
test('save preserves executable mode on POSIX', {skip:process.platform==='win32'}, async t => {
  const f=await setup(t); await f.login(); await fs.writeFile(path.join(f.root,'script.sh'),'echo a\n',{mode:0o755});
  const file=(await f.request('file?path=script.sh')).json;
  assert.equal((await f.request('save',{...file,content:'echo b\n'})).status,200);
  assert.equal((await fs.stat(path.join(f.root,'script.sh'))).mode&0o777,0o755);
});
test('oversize saves and stale deletes leave existing file intact', async t => {
  const f=await setup(t); await f.login(); await fs.writeFile(path.join(f.root,'keep.txt'),'keep');
  const file=(await f.request('file?path=keep.txt')).json;
  assert.equal((await f.request('save',{...file,content:'x'.repeat(MAX_FILE+1)})).status,413);
  await fs.writeFile(path.join(f.root,'keep.txt'),'external edit');
  assert.equal((await f.request('delete',{path:'keep.txt',version:file.version})).status,409);
  assert.equal(await fs.readFile(path.join(f.root,'keep.txt'),'utf8'),'external edit');
});
test('Git diff does not run external diff and commit does not run normal hooks', async t => {
  const f=await setup(t); await f.login(); await init(f);
  git(f.root,['config','diff.external','command-that-must-never-run']);
  await fs.writeFile(path.join(f.root,'.git','hooks','pre-commit'),'#!/bin/sh\nexit 1\n',{mode:0o755});
  await fs.writeFile(path.join(f.root,'a.txt'),'safe');
  assert.equal((await f.request('git/diff?path=a.txt')).status,200);
  assert.equal((await f.request('git/action',{action:'stage',path:'a.txt'})).status,200);
  assert.equal((await f.request('git/action',{action:'commit',message:'hooks disabled'})).status,200);
});

test('line-dense files and saves are bounded to protect native editor DOM', async t => {
  const f=await setup(t); await f.login(); await fs.writeFile(path.join(f.root,'dense.txt'),'\n'.repeat(20000));
  assert.equal((await f.request('file?path=dense.txt')).status,413);
  await fs.writeFile(path.join(f.root,'small.txt'),'keep');
  const file=(await f.request('file?path=small.txt')).json;
  assert.equal((await f.request('save',{...file,content:'\n'.repeat(20000)})).status,413);
  assert.equal(await fs.readFile(path.join(f.root,'small.txt'),'utf8'),'keep');
});
