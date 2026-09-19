#!/usr/bin/env node
import http from 'node:http';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {randomBytes, scrypt, scryptSync, timingSafeEqual} from 'node:crypto';
import {promisify} from 'node:util';
import {createFiles, digest, fail, HttpError, MAX_FILE} from './files.mjs';
import {createGit} from './git.mjs';

const scryptAsync = promisify(scrypt);
const PUBLIC = fileURLToPath(new URL('./public/', import.meta.url));
const TTL = 30 * 60 * 1000, ABSOLUTE_TTL = 8 * 60 * 60 * 1000;
export async function createApp({root, password, secureCookie = false, origin = '', basePath = ''}) {
  if (typeof password !== 'string' || password.length < 12 || password.length > 1024) throw new Error('PASSWORD must contain 12–1024 characters');
  if (basePath && !/^\/(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]+$/.test(basePath)) throw new Error('Invalid base path; use e.g. /code');
  if (origin && new URL(origin).origin !== origin) throw new Error('Origin must be an exact http(s) origin, without a path or trailing slash');
  if (origin && !/^https?:\/\//.test(origin)) throw new Error('Origin must use HTTP or HTTPS');
  if (origin.startsWith('https:') && !secureCookie) throw new Error('HTTPS origin requires --secure-cookie');
  const files = await createFiles(root), git = createGit(files.root);
  const salt = randomBytes(16), key = scryptSync(password, salt, 32);
  password = null;
  const sessions = new Map(), failures = new Map();
  const cookieName = 'lite_session_' + digest(basePath).slice(0, 8);
  let active = 0, mutating = false, authenticating = false;
  const metrics = {requests: 0, rejected: 0};
  function sweep() {
    const now = Date.now();
    for (const [id, session] of sessions) if (session.expires < now || session.created + ABSOLUTE_TTL < now) sessions.delete(id);
    for (const [ip, item] of failures) if (item.until < now) failures.delete(ip);
  }
  const cleanup = setInterval(sweep, 60000); cleanup.unref();
  function cookie(token, expired = false) {
    return `${cookieName}=${token}; Path=${basePath}/; HttpOnly; SameSite=Strict; Max-Age=${expired ? 0 : TTL / 1000}${secureCookie ? '; Secure' : ''}`;
  }
  function sessionFor(req, res) {
    const token = (req.headers.cookie || '').split(';').map(s => s.trim()).find(s => s.startsWith(cookieName + '='))?.slice(cookieName.length + 1);
    const session = token && sessions.get(token);
    const now = Date.now();
    if (!session || session.expires < now || session.created + ABSOLUTE_TTL < now) {
      if (token) sessions.delete(token);
      fail(401, 'Sign in to continue');
    }
    session.expires = now + TTL;
    res.setHeader('Set-Cookie', cookie(token));
    return {token, ...session};
  }
  function sameOrigin(req) {
    const expected = origin || `http://${req.headers.host}`;
    if (req.headers.origin !== expected || req.headers['sec-fetch-site'] === 'cross-site') fail(403, 'Cross-origin request rejected');
    if (!(req.headers['content-type'] || '').startsWith('application/json')) fail(415, 'JSON request required');
  }
  async function body(req, max = 6 * MAX_FILE + 4096) {
    if (Number(req.headers['content-length']) > max) fail(413, 'Request too large');
    const chunks = []; let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > max) fail(413, 'Request too large');
      chunks.push(chunk);
    }
    try {
      const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!value || typeof value !== 'object' || Array.isArray(value)) fail(400, 'JSON object required');
      return value;
    } catch (e) { if (e instanceof HttpError) throw e; fail(400, 'Invalid JSON'); }
  }
  async function exclusive(fn) {
    if (mutating) fail(409, 'Another workspace operation is running; retry when it finishes');
    mutating = true;
    try { return await fn(); } finally { mutating = false; }
  }
  function json(res, status, value) { res.writeHead(status, {'Content-Type': 'application/json; charset=utf-8'}); res.end(JSON.stringify(value)); }
  async function handler(req, res) {
    metrics.requests++;
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
    if (active >= 4) { metrics.rejected++; return json(res, 503, {error: 'Server busy; retry shortly'}); }
    active++;
    try {
      if ((req.url || '').length > 8192) fail(414, 'URL too long');
      const url = new URL(req.url, 'http://localhost');
      if (url.pathname === (basePath || '/') && basePath) { res.writeHead(302, {Location: basePath + '/'}); res.end(); return; }
      if (!url.pathname.startsWith(basePath + '/')) fail(404, 'Not found');
      const route = url.pathname.slice(basePath.length);
      if (req.method === 'GET' && ['/', '/app.js', '/style.css'].includes(route)) {
        const name = route === '/' ? 'index.html' : route.slice(1);
        const content = await fs.readFile(path.join(PUBLIC, name));
        res.writeHead(200, {'Content-Type': name.endsWith('.html') ? 'text/html; charset=utf-8' : name.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'text/css; charset=utf-8'});
        res.end(content); return;
      }
      if (req.method === 'POST') sameOrigin(req);
      if (route === '/api/login' && req.method === 'POST') {
        const {password: candidate} = await body(req, 4096);
        const ip = req.socket.remoteAddress || 'unknown';
        sweep();
        const rate = failures.get(ip) || {count: 0, until: Date.now() + 5 * 60000};
        if (rate.count >= 5 || authenticating) fail(429, 'Too many login attempts. Try again later.');
        if (failures.size >= 512 && !failures.has(ip)) fail(429, 'Login capacity reached. Try again later.');
        if (typeof candidate !== 'string' || candidate.length > 1024) fail(400, 'Invalid password');
        rate.count++; failures.set(ip, rate); authenticating = true;
        try {
          const actual = await scryptAsync(candidate, salt, 32);
          if (!timingSafeEqual(key, actual)) fail(401, 'Incorrect password');
        } finally { authenticating = false; }
        failures.delete(ip);
        if (sessions.size >= 64) sessions.delete(sessions.keys().next().value);
        const token = randomBytes(32).toString('hex');
        sessions.set(token, {csrf: randomBytes(32).toString('hex'), created: Date.now(), expires: Date.now() + TTL});
        res.setHeader('Set-Cookie', cookie(token)); json(res, 200, {ok: true}); return;
      }
      const session = sessionFor(req, res);
      if (req.method === 'GET') {
        if (route === '/api/session') json(res, 200, {csrf: session.csrf, workspace: files.root, pathStyle: process.platform === 'win32' ? 'windows' : 'posix', maxFileBytes: MAX_FILE});
        else if (route === '/api/files') json(res, 200, await files.list(url.searchParams.get('path') || ''));
        else if (route === '/api/file') json(res, 200, await files.read(url.searchParams.get('path')));
        else if (route === '/api/git/status') json(res, 200, await exclusive(() => git.status()));
        else if (route === '/api/git/diff') json(res, 200, await exclusive(() => git.diff(url.searchParams.get('path'), url.searchParams.get('staged') === '1')));
        else fail(404, 'Not found');
      } else if (req.method === 'POST') {
        if (req.headers['x-lite-csrf'] !== session.csrf) fail(403, 'Invalid CSRF token');
        const data = await body(req, route === '/api/save' ? 6 * MAX_FILE + 4096 : 16384);
        if (route === '/api/logout') { sessions.delete(session.token); res.setHeader('Set-Cookie', cookie('', true)); json(res, 200, {ok: true}); }
        else if (route === '/api/save') json(res, 200, await exclusive(() => files.save(data)));
        else if (route === '/api/create') json(res, 200, await exclusive(() => files.create(data)));
        else if (route === '/api/delete') json(res, 200, await exclusive(() => files.remove(data)));
        else if (route === '/api/git/action') json(res, 200, await exclusive(() => git.action(data)));
        else fail(404, 'Not found');
      } else fail(405, 'Method not allowed');
    } catch (e) {
      const status = e.status || ({ENOENT:404, EEXIST:409, ENOTDIR:400, EISDIR:400, EPERM:403, EACCES:403, EBUSY:409}[e.code]) || 500;
      const error = e.status ? e.message : status === 500 ? 'Internal operation failed' : `${e.code}: operation could not be completed`;
      if (!res.headersSent && !res.destroyed) json(res, status, {error: error.replace(/(https?:\/\/)[^\s/@]+@/g, '$1[redacted]@')});
      else if (!res.destroyed) res.end();
    } finally { active--; }
  }
  const server = http.createServer({maxHeaderSize: 8192, requestTimeout: 30000, headersTimeout: 10000, keepAliveTimeout: 5000}, handler);
  server.maxConnections = 32;
  server.on('close', () => { clearInterval(cleanup); git.stop(); sessions.clear(); failures.clear(); key.fill(0); });
  return {server, metrics, root: files.root, async close() { git.stop(); server.closeIdleConnections(); await new Promise(resolve => server.close(resolve)); }};
}

export function parseArgs(argv, env = process.env) {
  const options = {root: process.cwd(), host: '127.0.0.1', port: 8080, password: env.PASSWORD, secureCookie: false, origin: '', basePath: ''};
  let rootGiven = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') { options.help = true; continue; }
    if (arg === '--secure-cookie') { options.secureCookie = true; continue; }
    const flags = {'--root':'root','--host':'host','--port':'port','--origin':'origin','--base-path':'basePath'};
    if (flags[arg]) { if (!argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error('Missing value for ' + arg); options[flags[arg]] = argv[++i]; if (arg === '--root') rootGiven = true; }
    else if (!arg.startsWith('-') && !rootGiven) { options.root = arg; rootGiven = true; }
    else throw new Error('Unsupported option: ' + arg + '. Use --help; legacy VS Code options are not supported.');
  }
  options.port = Number(options.port);
  if (!Number.isInteger(options.port) || options.port < 1 || options.port > 65535) throw new Error('Invalid port');
  if (!options.help && !['127.0.0.1','::1','localhost'].includes(options.host) && (!options.secureCookie || !options.origin.startsWith('https://'))) throw new Error('Non-loopback binding requires --secure-cookie and --origin https://your-domain. Put a TLS reverse proxy in front; do not expose this HTTP port directly.');
  return options;
}
async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log('code-server lite — files + Git, no VS Code runtime\n\nPASSWORD=<12+ characters> node lite/server.mjs [directory]\n  --root PATH --host 127.0.0.1 --port 8080\n  --origin https://editor.example.com --secure-cookie\n  --base-path /code   (optional)\n\nFor remote use, terminate HTTPS at a reverse proxy. Passwords are accepted only via PASSWORD, never a CLI argument.');
    return;
  }
  delete process.env.PASSWORD;
  const app = await createApp(options); options.password = null;
  await new Promise((resolve, reject) => { app.server.once('error', reject); app.server.listen(options.port, options.host, resolve); });
  console.log(`code-server lite listening on http://${options.host}:${options.port}${options.basePath}/`);
  console.log(`Workspace: ${app.root}; remote users must connect through HTTPS. No extension host, language server or file watcher is running.`);
  for (const signal of ['SIGINT','SIGTERM']) process.once(signal, () => { app.close().then(() => process.exit(0)); const timer = setTimeout(() => process.exit(1), 5000); timer.unref(); });
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main().catch(e => { console.error(e.message); process.exitCode = 1; });
