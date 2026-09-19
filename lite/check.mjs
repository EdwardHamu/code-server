import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
for (const name of ['server.mjs','files.mjs','git.mjs','state.mjs','public/app.js']) {
  execFileSync(process.execPath,['--check',fileURLToPath(new URL(name,import.meta.url))],{stdio:'inherit'});
}
console.log('Lightweight runtime syntax checked. No bundler, dependencies or VS Code build required.');
