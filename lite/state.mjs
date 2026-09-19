import * as fs from 'node:fs/promises';
import path from 'node:path';
import {randomBytes} from 'node:crypto';

export const MAX_RECENT = 30;
// Persists the last opened directory and a bounded history of explicitly opened
// directories. Writes are serialized and atomic (temp file + rename).
export async function createState(file) {
  let data = {lastDirectory: '', recentDirectories: []};
  let queue = Promise.resolve();
  if (file) {
    try {
      const parsed = JSON.parse(await fs.readFile(file, 'utf8'));
      const recent = Array.isArray(parsed.recentDirectories) ? parsed.recentDirectories : [];
      data = {
        lastDirectory: typeof parsed.lastDirectory === 'string' ? parsed.lastDirectory : '',
        recentDirectories: recent.filter(e => e && typeof e.path === 'string' && Number.isFinite(e.openedAt)).slice(0, MAX_RECENT)
      };
    } catch (e) { if (e.code !== 'ENOENT') throw new Error(`Cannot read state file ${file}: ${e.message}`); }
  }
  function persist() {
    if (!file) return queue;
    const snapshot = JSON.stringify(data, null, 2) + '\n';
    queue = queue.then(async () => {
      await fs.mkdir(path.dirname(file), {recursive: true, mode: 0o700});
      const temp = path.join(path.dirname(file), '.state-' + randomBytes(8).toString('hex'));
      try { await fs.writeFile(temp, snapshot, {mode: 0o600}); await fs.rename(temp, file); }
      finally { await fs.unlink(temp).catch(() => {}); }
    }).catch(() => {});
    return queue;
  }
  function recent() { return {lastDirectory: data.lastDirectory, recentDirectories: data.recentDirectories.map(e => ({...e}))}; }
  function remember(directory) {
    data.lastDirectory = directory;
    data.recentDirectories = [{path: directory, openedAt: Date.now()}, ...data.recentDirectories.filter(e => e.path !== directory)].slice(0, MAX_RECENT);
    return persist();
  }
  function forget(directory) {
    data.recentDirectories = data.recentDirectories.filter(e => e.path !== directory);
    if (data.lastDirectory === directory) data.lastDirectory = data.recentDirectories[0]?.path || '';
    return persist();
  }
  function clear() { data = {lastDirectory: '', recentDirectories: []}; return persist(); }
  return {file, recent, remember, forget, clear, flush: () => queue};
}
