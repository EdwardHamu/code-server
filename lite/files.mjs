import * as fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes, createHash } from 'node:crypto';

export const MAX_FILE = 1024 * 1024;
export const MAX_LINES = 20000;
function checkLines(text) {
  let lines = 1;
  for (let i = 0; i < text.length; i++) if (text.charCodeAt(i) === 10 && ++lines > MAX_LINES) fail(413, 'File exceeds 20000-line editing limit');
}
export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
export const fail = (status, message) => { throw new HttpError(status, message); };
export const digest = data => createHash('sha256').update(data).digest('hex');
export function relativeName(name, allowRoot = false) {
  if (typeof name !== 'string' || name.length > 2048) fail(400, 'Invalid path');
  if (name === '' && allowRoot) return name;
  if (!name || /[\\\x00-\x1f:]/.test(name) || name.split('/').some(p => !p || p === '.' || p === '..' || p.toLowerCase() === '.git' || /[. ]$/.test(p) || /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(p))) fail(400, 'Unsafe path');
  return name;
}
export function inside(root, target) {
  const rel = path.relative(root, target);
  return rel === '' || (!rel.startsWith('..' + path.sep) && rel !== '..' && !path.isAbsolute(rel));
}
// Absolute paths are server-native. Relative API paths remain compatible with --root.
export function fileTarget(root, name, allowRoot = false, flavor = path) {
  if (typeof name !== 'string' || name.length > 2048) fail(400, 'Invalid path');
  if (name === '' && allowRoot) return root;
  const windows = flavor === path.win32;
  const absolute = windows ? /^[a-z]:[\\/]/i.test(name) : name.startsWith('/');
  if (!absolute) { relativeName(name, allowRoot); return flavor.join(root, name); }
  // No UNC shares, device namespaces, drive-relative paths or ADS.
  const normalized = windows ? name.replace(/\\/g, '/') : name;
  const anchor = flavor.parse(normalized).root;
  const rest = normalized.slice(anchor.length).replace(/\/$/, '');
  if (rest) relativeName(rest);
  else if (!allowRoot) fail(400, 'A file or directory name is required');
  return flavor.join(anchor, rest);
}
export async function createFiles(directory) {
  const root = await fs.realpath(directory);
  if (!(await fs.stat(root)).isDirectory()) fail(400, 'Workspace must be a directory');
  async function resolve(name, {newLeaf = false, allowRoot = false} = {}) {
    const target = fileTarget(root, name, allowRoot);
    const anchor = path.parse(target).root;
    let current = anchor;
    const parts = target.slice(anchor.length).split(path.sep).filter(Boolean);
    for (const [i, part] of parts.entries()) {
      current = path.join(current, part);
      let st;
      try { st = await fs.lstat(current); }
      catch (e) { if (e.code === 'ENOENT' && newLeaf && i === parts.length - 1) return current; throw e; }
      if (st.isSymbolicLink() || st.isFile() && st.nlink > 1) fail(403, 'Links are not exposed by this editor');
      if (i < parts.length - 1 && !st.isDirectory()) fail(400, 'Parent is not a directory');
    }
    return current;
  }
  async function bytes(name) {
    const filename = await resolve(name);
    const handle = await fs.open(filename, 'r');
    try {
      const st = await handle.stat();
      if (!st.isFile() || st.nlink > 1) fail(400, 'Not a regular editable file');
      if (st.size > MAX_FILE) fail(413, 'File exceeds 1 MiB editing limit');
      // Fixed-size allocation also bounds a file growing after stat().
      const buffer = Buffer.alloc(Math.min(st.size + 1, MAX_FILE + 1));
      let offset = 0;
      while (offset < buffer.length) {
        const {bytesRead} = await handle.read(buffer, offset, buffer.length - offset, offset);
        if (!bytesRead) break;
        offset += bytesRead;
      }
      if (offset > st.size) fail(409, 'File changed while reading; reload');
      return {data: buffer.subarray(0, offset), mode: st.mode};
    } finally { await handle.close(); }
  }
  async function read(name) {
    const {data} = await bytes(name);
    if (data.includes(0)) fail(415, 'Binary files cannot be edited');
    let text;
    try { text = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(data); }
    catch { fail(415, 'Only UTF-8 text is supported; file was not modified'); }
    checkLines(text);
    const bom = text.startsWith('\uFEFF');
    if (bom) text = text.slice(1);
    const crlf = text.includes('\r\n');
    return {path: await resolve(name), content: text, version: digest(data), bytes: data.length, bom, newline: crlf ? '\r\n' : '\n'};
  }
  async function list(name = '') {
    const filename = await resolve(name, {allowRoot: true});
    const entries = [];
    let truncated = false;
    const dir = await fs.opendir(filename);
    for await (const entry of dir) {
      if (entry.name.toLowerCase() === '.git' || entry.name.startsWith('.lite-save-')) continue;
      if (entries.length >= 1000) { truncated = true; break; }
      entries.push({name: entry.name, path: path.join(filename, entry.name),
        kind: entry.isSymbolicLink() ? 'link' : entry.isDirectory() ? 'directory' : entry.isFile() ? 'file' : 'special'});
    }
    entries.sort((a, b) => (a.kind !== 'directory') - (b.kind !== 'directory') || a.name.localeCompare(b.name));
    return {path: filename, parent: path.dirname(filename), entries, truncated};
  }
  async function checkVersion(name, version) {
    if (typeof version !== 'string' || !/^[a-f0-9]{64}$/.test(version)) fail(400, 'A saved file version is required');
    const current = await bytes(name);
    if (digest(current.data) !== version) fail(409, 'File changed on disk. Reload before overwriting.');
    return current;
  }
  async function save({path: name, content, version, bom = false, newline = '\n'}) {
    if (typeof content !== 'string' || !['\n', '\r\n'].includes(newline) || typeof bom !== 'boolean' || content.includes('\0')) fail(400, 'Invalid text payload');
    checkLines(content);
    const output = Buffer.from((bom ? '\uFEFF' : '') + content.replace(/\r\n/g, '\n').replace(/\n/g, newline));
    if (output.length > MAX_FILE) fail(413, 'File exceeds 1 MiB editing limit');
    const filename = await resolve(name);
    const old = await checkVersion(name, version);
    const temp = path.join(path.dirname(filename), '.lite-save-' + randomBytes(12).toString('hex'));
    let handle;
    try {
      handle = await fs.open(temp, 'wx', old.mode & 0o777);
      await handle.writeFile(output); await handle.chmod(old.mode & 0o777); await handle.sync(); await handle.close(); handle = null;
      await checkVersion(name, version); await resolve(name);
      await fs.rename(temp, filename);
    } finally { await handle?.close(); await fs.unlink(temp).catch(() => {}); }
    return {version: digest(output), bytes: output.length};
  }
  async function create({path: name, directory = false}) {
    const filename = await resolve(name, {newLeaf: true});
    if (directory) await fs.mkdir(filename);
    else { const h = await fs.open(filename, 'wx', 0o600); await h.close(); }
    return {ok: true, path: filename, parent: path.dirname(filename)};
  }
  async function remove({path: name, version}) {
    const filename = await resolve(name);
    await checkVersion(name, version);
    await fs.unlink(filename);
    return {ok: true};
  }
  return {root, resolve, read, list, save, create, remove};
}
