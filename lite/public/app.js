'use strict';
const $ = id => document.getElementById(id);
const state = {csrf: '', file: null, dirty: false, busy: false, opening: 0, treeEpoch: 0, gitEpoch: 0, directory: '', parent: '', pathStyle: 'posix'};
const code = $('code');
function notice(text, error = false) { $('notice').textContent = text; $('notice').classList.toggle('error', error); }
function login(show) { $('login-overlay').hidden = !show; if (show) $('password').focus(); }
async function api(route, data) {
  const response = await fetch('api/' + route, {method: data === undefined ? 'GET' : 'POST', credentials: 'same-origin', headers: data === undefined ? {} : {'Content-Type':'application/json', 'X-Lite-CSRF':state.csrf}, ...(data === undefined ? {} : {body: JSON.stringify(data)})});
  const result = await response.json();
  if (!response.ok) {
    if (response.status === 401) login(true);
    throw new Error(result.error || '请求失败');
  }
  return result;
}
function on(id, fn) { $(id).addEventListener('click', () => Promise.resolve().then(fn).catch(e => notice(e.message, true))); }
function button(text, fn, cls = '') { const b = document.createElement('button'); b.textContent = text; b.className = cls; b.addEventListener('click', () => Promise.resolve().then(fn).catch(e => notice(e.message, true))); return b; }
function canLeave() { return !state.dirty || confirm('当前文件尚未保存。放弃这些修改？'); }
function setDirty(value) { state.dirty = value; $('dirty').textContent = value ? '●' : ''; $('save').disabled = !state.file || !value || state.busy; }
function escapeHTML(text) { return text.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
let renderTimer, scrollFrame, renderLines = null, renderLineCount = 1, lastFirst = -1;
function render() {
  clearTimeout(renderTimer);
  const value = code.value;
  renderLineCount = 1;
  for (let i = 0; i < value.length; i++) if (value.charCodeAt(i) === 10) renderLineCount++;
  renderLines = $('highlight').checked && value.length <= 128000 && renderLineCount <= 10000 ? value.split('\n') : null;
  if (renderLines?.some(line => line.length > 4000)) renderLines = null;
  $('editor').classList.toggle('plain', !renderLines);
  renderViewport(true); position();
}
function colorVisible(value) {
  const keywords = new Set('const let var function return if else for while class new import export from async await try catch throw def with as in None True False true false null public private static void'.split(' '));
    const parts = []; let i = 0, plainStart = 0;
    while (i < value.length) {
      const start = i, c = value[i]; let kind = '';
      if (value.startsWith('//', i) || c === '#') { const end = value.indexOf('\n', i); i = end < 0 ? value.length : end; kind = 'comment'; }
      else if (value.startsWith('/*', i)) { const end = value.indexOf('*/', i + 2); i = end < 0 ? value.length : end + 2; kind = 'comment'; }
      else if ('"\'`'.includes(c)) { i++; while (i < value.length) { if (value[i] === '\\') { i += 2; continue; } if (value[i++] === c) break; } i = Math.min(i, value.length); kind = 'string'; }
      else if (/[0-9]/.test(c)) { i++; while (i < value.length && /[0-9.]/.test(value[i])) i++; kind = 'number'; }
      else if (/[A-Za-z_$]/.test(c)) { i++; while (i < value.length && /[\w$]/.test(value[i])) i++; if (keywords.has(value.slice(start, i))) kind = 'keyword'; }
      else i++;
      if (kind) { parts.push(escapeHTML(value.slice(plainStart, start)), '<span class="tok-' + kind + '">', escapeHTML(value.slice(start, i)), '</span>'); plainStart = i; }
    }
  return parts.join('') + escapeHTML(value.slice(plainStart)) + '\n';
}
function renderViewport(force = false) {
  const first = Math.max(0, Math.min(renderLineCount - 1, Math.floor(code.scrollTop / 21)));
  const count = Math.min(200, Math.ceil(code.clientHeight / 21) + 2);
  const offset = code.scrollTop - first * 21;
  $('gutter-lines').style.transform = `translateY(${-offset}px)`;
  $('highlight-lines').style.transform = `translate(${-code.scrollLeft}px, ${-offset}px)`;
  if (force || first !== lastFirst) {
    lastFirst = first;
    $('gutter-lines').textContent = Array.from({length: Math.min(count, renderLineCount - first)}, (_, i) => first + i + 1).join('\n');
    $('highlight-lines').innerHTML = renderLines ? colorVisible(renderLines.slice(first, first + count).join('\n')) : '';
  }
}
function position() {
  const before = code.value.slice(0, code.selectionStart), row = before.split('\n').length, col = before.length - before.lastIndexOf('\n');
  $('position').textContent = state.file ? `Ln ${row}, Col ${col} · UTF-8${state.file.bom ? ' BOM' : ''} · ${state.file.newline === '\r\n' ? 'CRLF' : 'LF'}` : 'UTF-8 · 单文件';
}
function syncScroll() { if (!scrollFrame) scrollFrame = requestAnimationFrame(() => { scrollFrame = 0; renderViewport(); }); }
window.addEventListener('resize', () => renderViewport(true));
code.addEventListener('scroll', syncScroll, {passive:true});
code.addEventListener('input', () => { setDirty(true); clearTimeout(renderTimer); renderTimer = setTimeout(render, 150); });
code.addEventListener('paste', e => {
  const incoming = e.clipboardData?.getData('text/plain');
  if (incoming === undefined) return;
  const length = code.value.length - (code.selectionEnd - code.selectionStart) + incoming.length;
  if (length > 1048576) { e.preventDefault(); notice('粘贴超过 1 MiB 编辑限额', true); return; }
  const result = code.value.slice(0, code.selectionStart) + incoming + code.value.slice(code.selectionEnd);
  let lines = 1;
  for (let i = 0; i < result.length; i++) if (result.charCodeAt(i) === 10) lines++;
  if (lines > 20000 || new TextEncoder().encode(result).length > 1048576) { e.preventDefault(); notice('粘贴超过 1 MiB 或 20,000 行编辑限额', true); }
});
code.addEventListener('click', position); code.addEventListener('keyup', position);
$('highlight').addEventListener('change', render);
code.addEventListener('keydown', e => {
  if (e.key === 'Tab') {
    e.preventDefault();
    if (!e.shiftKey) {
      if (!document.execCommand('insertText', false, '  ')) { code.setRangeText('  ', code.selectionStart, code.selectionEnd, 'end'); code.dispatchEvent(new Event('input')); }
    }
  }
});
window.addEventListener('beforeunload', e => { if (state.dirty) { e.preventDefault(); e.returnValue = ''; } });
window.addEventListener('keydown', e => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save().catch(err => notice(err.message, true)); }
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f' && state.file && $('login-overlay').hidden) { e.preventDefault(); $('find-text').focus(); }
});
async function openFile(path, {discard = false} = {}) {
  if (state.busy || (!discard && !canLeave())) return;
  // Keep the old buffer until the request succeeds. Lock editing to avoid late
  // responses overwriting keystrokes entered while a file is loading.
  const id = ++state.opening;
  state.busy = true; code.readOnly = true; setDirty(state.dirty);
  try {
    const file = await api('file?path=' + encodeURIComponent(path));
    if (id !== state.opening) return;
    state.file = file; code.value = file.content.replace(/\r\n/g, '\n'); delete file.content;
    $('filename').textContent = file.path;
    $('welcome').hidden = true; $('editor').hidden = false; $('diff-panel').hidden = true;
    code.scrollTop = code.scrollLeft = 0; setDirty(false); render(); notice(`${file.bytes.toLocaleString()} bytes · 已载入`);
  } finally { state.busy = false; code.readOnly = false; setDirty(state.dirty); }
}
async function save() {
  if (!state.file || !state.dirty || state.busy) return;
  const content = code.value, file = state.file;
  state.busy = true; setDirty(true);
  try {
    const result = await api('save', {path:file.path, content, version:file.version, bom:file.bom, newline:file.newline});
    Object.assign(file, result); setDirty(code.value !== content); notice('已保存到服务器');
  } finally { state.busy = false; setDirty(state.dirty); }
}
async function populate(container, path, epoch) {
  const result = await api('files?path=' + encodeURIComponent(path));
  if (epoch !== state.treeEpoch || !container.isConnected) return;
  container.replaceChildren();
  for (const item of result.entries) {
    const wrapper = document.createElement('div');
    const node = button((item.kind === 'directory' ? '▸ ' : item.kind === 'file' ? '· ' : '↗ ') + item.name, async () => {
      if (item.kind === 'file') {
        await openFile(item.path);
        if (state.file?.path === item.path) { document.querySelectorAll('.selected').forEach(el => el.classList.remove('selected')); node.classList.add('selected'); }
      } else if (item.kind === 'directory') {
        const existing = wrapper.querySelector('.tree-node');
        if (existing) { existing.remove(); node.textContent = '▸ ' + item.name; }
        else { const inner = document.createElement('div'); inner.className = 'tree-node'; inner.textContent = '加载中…'; wrapper.append(inner); node.textContent = '▾ ' + item.name; try { await populate(inner, item.path, epoch); } catch (e) { inner.remove(); node.textContent = '▸ ' + item.name; throw e; } }
      } else notice('链接和特殊文件不会由此编辑器打开', true);
    }, 'tree-button');
    wrapper.append(node); container.append(wrapper);
  }
  if (result.truncated) { const p = document.createElement('p'); p.className = 'hint'; p.textContent = '为控制内存，本目录只显示前 1000 项。'; container.append(p); }
  return result;
}
async function refreshFiles(target = state.directory) {
  const epoch = ++state.treeEpoch;
  const result = await populate($('tree'), target, epoch);
  if (!result || epoch !== state.treeEpoch) return;
  state.directory = result.path; state.parent = result.parent;
  $('directory-path').value = result.path;
  $('parent-folder').disabled = result.parent === result.path;
}
function absolutePath(value) {
  return state.pathStyle === 'windows' ? /^[a-z]:[\\/]/i.test(value) : value.startsWith('/');
}
async function browseDirectory() {
  const target = $('directory-path').value;
  if (!absolutePath(target)) throw new Error('请输入服务器绝对路径');
  await refreshFiles(target);
}
async function createEntry(directory) {
  const prefix = state.directory.replace(/[\\/]$/, '') + (state.pathStyle === 'windows' ? '\\' : '/');
  const name = prompt(directory ? '新目录的服务器绝对路径（父目录须已存在）' : '新文件的服务器绝对路径（父目录须已存在）', prefix);
  if (!name) return;
  if (!absolutePath(name)) throw new Error('请输入服务器绝对路径');
  const result = await api('create', {path:name, directory});
  await refreshFiles(result.parent); notice('已创建 ' + result.path);
  if (!directory) await openFile(result.path);
}
function selectTab(git) {
  $('files-panel').hidden = git; $('git-panel').hidden = !git;
  $('files-tab').classList.toggle('active', !git); $('git-tab').classList.toggle('active', git);
}
async function refreshGit() {
  const epoch = ++state.gitEpoch;
  notice('正在读取 Git 状态…');
  const result = await api('git/status');
  if (epoch !== state.gitEpoch) return;
  $('branch-label').textContent = '分支：' + result.branch;
  $('branches').replaceChildren(...result.branches.map(name => { const option = document.createElement('option'); option.textContent = name; option.value = name; option.selected = name === result.branch; return option; }));
  $('changes').replaceChildren();
  for (const file of result.files) {
    const row = document.createElement('div'); row.className = 'change';
    const name = document.createElement('div'); name.className = 'path';
    const status = document.createElement('span'); status.className = 'status'; status.textContent = file.status + '  ';
    name.append(status, document.createTextNode(file.path)); row.append(name);
    row.append(button('工作区差异', () => showDiff(file.path, false)), button('暂存区差异', () => showDiff(file.path, true)));
    if (file.status === '??' || file.status[1] !== ' ') row.append(button('暂存', () => gitAction({action:'stage',path:file.path})));
    if (file.status !== '??' && file.status[0] !== ' ') row.append(button('取消暂存', () => gitAction({action:'unstage',path:file.path})));
    $('changes').append(row);
  }
  notice(result.truncated ? 'Git 列表仅显示前 1000 项，请缩小工作区。' : `${result.files.length} 项变更 · 手动刷新`);
}
async function showDiff(path, staged) {
  const result = await api('git/diff?path=' + encodeURIComponent(path) + '&staged=' + Number(staged));
  $('diff-title').textContent = `${staged ? '暂存区' : '工作区'} · ${path}`;
  $('diff').textContent = result.text.slice(0, 256000) + (result.text.length > 256000 ? '\n…显示已截断，以限制内存占用。' : '') || '没有差异。未跟踪文件须先暂存，再查看暂存区差异。';
  $('diff-panel').hidden = false;
}
async function gitAction(data) {
  if (state.busy) return;
  if (state.dirty) throw new Error('先保存当前编辑内容，再执行 Git 操作。');
  const changing = ['switch','branch','pull'].includes(data.action);
  if (['commit','push','pull','switch','branch'].includes(data.action) && !confirm('确认执行 Git ' + data.action + '？')) return;
  state.busy = true; code.readOnly = true; setDirty(state.dirty);
  try {
    notice('Git ' + data.action + '…'); await api('git/action', data);
    if (data.action === 'commit') $('commit-message').value = '';
    if (changing) {
      // The old file revision is invalid after branch changes or pulls.
      state.file = null; code.value = ''; $('filename').textContent = '请选择文件'; $('editor').hidden = true; $('welcome').hidden = false; render(); $('diff').textContent = ''; $('diff-panel').hidden = true;
      await refreshFiles();
    }
    await refreshGit();
  } finally { state.busy = false; code.readOnly = false; setDirty(state.dirty); }
}
async function enter() {
  const session = await api('session'); state.csrf = session.csrf; state.pathStyle = session.pathStyle; $('workspace').textContent = session.workspace; login(false);
  await refreshFiles(); notice('已连接 · Ctrl/Cmd S 保存 · 单文件上限 1 MiB');
}
$('login-form').addEventListener('submit', async e => {
  e.preventDefault(); $('login-button').disabled = true; $('login-error').textContent = '';
  try { await api('login', {password:$('password').value}); $('password').value = ''; await enter(); }
  catch (err) { $('login-error').textContent = err.message; }
  finally { $('login-button').disabled = false; }
});
on('open-directory', browseDirectory);
on('parent-folder', () => refreshFiles(state.parent));
$('directory-path').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); browseDirectory().catch(err => notice(err.message, true)); } });
on('save', save); on('refresh-files', refreshFiles); on('files-tab', () => selectTab(false));
on('git-tab', async () => { selectTab(true); await refreshGit(); }); on('refresh-git', refreshGit);
on('new-file', () => createEntry(false)); on('new-folder', () => createEntry(true));
on('reload-file', () => state.file && openFile(state.file.path));
on('delete-file', async () => {
  if (!state.file || state.busy || !confirm('永久删除当前文件？未保存修改也会丢失。')) return;
  state.busy = true; code.readOnly = true;
  try {
    await api('delete', {path:state.file.path, version:state.file.version});
    state.file = null; code.value = ''; setDirty(false); render(); $('filename').textContent = '请选择文件'; $('editor').hidden = true; $('welcome').hidden = false; await refreshFiles(); notice('文件已删除');
  } finally { state.busy = false; code.readOnly = false; setDirty(state.dirty); }
});
on('close-diff', () => { $('diff-panel').hidden = true; $('diff').textContent = ''; });
on('commit', () => gitAction({action:'commit', message:$('commit-message').value}));
for (const action of ['fetch','pull','push']) on(action, () => gitAction({action}));
on('switch-branch', () => gitAction({action:'switch',branch:$('branches').value}));
on('new-branch', () => { const branch = prompt('新分支名称'); if (branch) return gitAction({action:'branch',branch}); });
function findNext() {
  const term = $('find-text').value; if (!term || !state.file) return false;
  let index = code.value.indexOf(term, code.selectionEnd); if (index < 0) index = code.value.indexOf(term);
  if (index < 0) { notice('没有匹配项'); return false; }
  code.focus(); code.setSelectionRange(index, index + term.length); code.scrollTop = Math.max(0, (code.value.slice(0,index).split('\n').length - 1) * 21 - code.clientHeight / 2); position(); return true;
}
on('find-next', findNext);
on('replace', () => {
  if (state.busy || !state.file || !$('find-text').value) return;
  if (code.value.slice(code.selectionStart,code.selectionEnd) === $('find-text').value) { code.focus(); if (!document.execCommand('insertText',false,$('replace-text').value)) { code.setRangeText($('replace-text').value,code.selectionStart,code.selectionEnd,'end'); code.dispatchEvent(new Event('input')); } }
  else findNext();
});
on('logout', async () => {
  if (state.busy || !canLeave()) return;
  state.busy = true; code.readOnly = true;
  try { await api('logout', {}); state.csrf = ''; state.file = null; setDirty(false); code.value = ''; $('tree').replaceChildren(); $('changes').replaceChildren(); $('diff').textContent = ''; $('diff-panel').hidden = true; render(); $('filename').textContent = '欢迎'; $('editor').hidden = true; $('welcome').hidden = false; login(true); }
  finally { state.busy = false; code.readOnly = false; setDirty(state.dirty); }
});
enter().catch(e => { notice(e.message, true); login(true); });
