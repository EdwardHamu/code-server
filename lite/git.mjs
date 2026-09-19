import {spawn} from 'node:child_process';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {fail, relativeName} from './files.mjs';

const OUTPUT_LIMIT = 2 * 1024 * 1024;
export function createGit(root) {
  let child = null;
  const env = {};
  for (const key of ['PATH','Path','HOME','USERPROFILE','HOMEDRIVE','HOMEPATH','SystemRoot','SYSTEMROOT','TEMP','TMP','TMPDIR','SSH_AUTH_SOCK','USER','LOGNAME','LANG']) if (process.env[key]) env[key] = process.env[key];
  Object.assign(env, {GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never', GIT_LITERAL_PATHSPECS: '1', GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C.UTF-8'});
  function terminate(proc) {
    if (!proc?.pid) return;
    if (process.platform === 'win32') {
      const killer = spawn('taskkill', ['/pid', String(proc.pid), '/t', '/f'], {windowsHide: true, stdio: 'ignore'});
      killer.on('error', () => proc.kill()); killer.unref();
    } else { try { process.kill(-proc.pid, 'SIGKILL'); } catch { proc.kill(); } }
  }
  async function run(args, {timeout = 20000, accept = [0]} = {}) {
    return new Promise((resolve, reject) => {
      const proc = spawn('git', ['-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=' + path.join(root, '.git', 'lite-disabled-hooks'), ...args],
        {cwd: root, env, shell: false, windowsHide: true, detached: process.platform !== 'win32', stdio: ['ignore', 'pipe', 'pipe']});
      child = proc;
      let length = 0, problem = null;
      const stdout = [], stderr = [];
      const timer = setTimeout(() => { problem = 'Git operation timed out'; terminate(proc); }, timeout);
      function capture(target, chunk) {
        if (problem) return;
        length += chunk.length;
        if (length > OUTPUT_LIMIT) { problem = 'Git output exceeds 2 MiB; narrow the operation'; terminate(proc); }
        else target.push(chunk);
      }
      proc.stdout.on('data', b => capture(stdout, b)); proc.stderr.on('data', b => capture(stderr, b));
      proc.on('error', e => { clearTimeout(timer); if (child === proc) child = null; reject(e); });
      proc.on('close', code => {
        clearTimeout(timer); if (child === proc) child = null;
        const out = Buffer.concat(stdout).toString('utf8'), err = Buffer.concat(stderr).toString('utf8');
        if (problem) reject(Object.assign(new Error(problem), {status: 503}));
        else if (!accept.includes(code)) reject(Object.assign(new Error(err.trim().slice(0, 3000) || `Git exited ${code}`), {status: 400}));
        else resolve(out);
      });
    });
  }
  async function ensure() {
    let st;
    try { st = await fs.lstat(path.join(root, '.git')); } catch { fail(400, 'Open the root of a Git repository. Initialize it outside this editor first.'); }
    if (!st.isDirectory() || st.isSymbolicLink()) fail(403, 'Linked worktrees and external Git directories are not supported');
    const top = await fs.realpath((await run(['rev-parse', '--show-toplevel'])).trim());
    if (top !== root) fail(403, 'Git working tree must match workspace root');
  }
  function parseStatus(raw) {
    const fields = raw.split('\0'), files = [];
    for (let i = 0; i < fields.length && fields[i]; i++) {
      const entry = fields[i], status = entry.slice(0, 2), name = entry.slice(3).replace(/\/$/, '');
      const previous = /[RC]/.test(status) ? fields[++i] : undefined;
      files.push({path: name, status, ...(previous ? {previous} : {})});
    }
    return files;
  }
  async function status() {
    await ensure();
    const files = parseStatus(await run(['status', '--porcelain=v1', '-z', '--untracked-files=normal']));
    const branch = (await run(['symbolic-ref', '--short', '-q', 'HEAD'], {accept: [0, 1]})).trim() || '(detached HEAD)';
    const branches = (await run(['for-each-ref', '--format=%(refname:short)', '--count=1000', 'refs/heads'])).trim().split('\n').filter(Boolean);
    return {files: files.slice(0, 1000), truncated: files.length > 1000, branch, branches};
  }
  async function diff(name, staged = false) {
    relativeName(name); await ensure();
    return {text: await run(['diff', '--no-ext-diff', '--no-textconv', '--no-color', ...(staged ? ['--cached'] : []), '--', name])};
  }
  async function action({action, path: name, message, branch}) {
    await ensure();
    if (['stage','unstage'].includes(action)) {
      relativeName(name);
      const items = parseStatus(await run(['status', '--porcelain=v1', '-z', '--untracked-files=normal']));
      const item = items.find(f => f.path === name);
      if (!item) fail(409, 'File status changed. Refresh Git first.');
      const paths = [name];
      if (item.previous) { relativeName(item.previous); paths.push(item.previous); }
      if (action === 'stage') await run(['add', '--all', '--', ...paths]);
      else {
        const head = await run(['rev-parse', '--verify', '-q', 'HEAD'], {accept: [0, 1]});
        await run(head ? ['reset', '-q', 'HEAD', '--', ...paths] : ['rm', '--cached', '-r', '--', ...paths]);
      }
    } else if (action === 'commit') {
      if (typeof message !== 'string' || !message.trim() || message.length > 4000 || message.includes('\0')) fail(400, 'Enter a commit message (up to 4000 characters)');
      await run(['-c', 'commit.gpgSign=false', 'commit', '-m', message]);
    } else if (['switch','branch'].includes(action)) {
      if (typeof branch !== 'string' || branch.startsWith('-') || branch.length > 200) fail(400, 'Invalid branch name');
      await run(['check-ref-format', '--branch', branch]);
      if (branch.includes('@') || branch.includes('~') || branch.includes('^')) fail(400, 'Only literal branch names are allowed');
      const dirty = await run(['status', '--porcelain=v1', '-z']);
      if (dirty) fail(409, 'Commit or clean working-tree changes before switching branches');
      await run(action === 'branch' ? ['switch', '-c', branch] : ['switch', '--', branch]);
    } else if (['fetch','pull','push'].includes(action)) {
      if (action === 'pull' && await run(['status', '--porcelain=v1', '-z'])) fail(409, 'Commit or clean working-tree changes before pulling');
      await run(action === 'pull' ? ['-c','merge.autoStash=false','-c','rebase.autoStash=false','pull','--ff-only','--no-rebase'] : [action], {timeout: 60000});
    } else fail(400, 'Unsupported Git action');
    return {ok: true};
  }
  return {status, diff, action, stop: () => terminate(child)};
}
