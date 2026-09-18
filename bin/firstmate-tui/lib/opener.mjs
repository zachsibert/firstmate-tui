// lib/opener.mjs - open a URL in the user's default browser. The one write-like
// thing the board does besides `herdr agent focus`; it touches no file.
//
// The opener is spawned with an argv array (never a shell string), so a URL
// can carry no shell metacharacters into the command. Only http(s) URLs are
// accepted. macOS uses `open`, Linux `xdg-open`; --opener-cmd overrides both
// (tests inject a fake opener that records its argv).

import { spawn as nodeSpawn } from 'node:child_process';

export function defaultOpenerCmd(platform = process.platform) {
  if (platform === 'darwin') return ['open'];
  if (platform === 'linux') return ['xdg-open'];
  return null;
}

export function isOpenableUrl(url) {
  return typeof url === 'string' && /^https?:\/\/[^\s"'<>]+$/.test(url);
}

// Resolves once the opener has started (or, with wait=true, exited 0). The
// child is detached and unreferenced so quitting the board never waits on a
// browser; with wait=true (the --render-once path) it is not detached and the
// promise follows its exit code.
export function openUrl(url, { cmd = null, wait = false, spawn = nodeSpawn, platform = process.platform } = {}) {
  if (!isOpenableUrl(url)) return Promise.reject(new Error('not an http(s) URL'));
  const argv = Array.isArray(cmd) && cmd.length ? cmd : defaultOpenerCmd(platform);
  if (!argv) return Promise.reject(new Error(`no browser opener known for ${platform}`));
  return new Promise((resolve, reject) => {
    const [bin, ...prefix] = argv;
    let child;
    try {
      child = spawn(bin, [...prefix, url], { detached: !wait, stdio: 'ignore' });
    } catch (e) {
      reject(e);
      return;
    }
    let settled = false;
    child.on('error', (e) => {
      if (settled) return;
      settled = true;
      reject(new Error(e && e.code === 'ENOENT' ? `${bin} not found` : e.message));
    });
    if (wait) {
      child.on('exit', (code) => {
        if (settled) return;
        settled = true;
        if (code === 0) resolve();
        else reject(new Error(`${bin} exited ${code}`));
      });
    } else {
      child.on('spawn', () => {
        if (settled) return;
        settled = true;
        child.unref();
        resolve();
      });
    }
  });
}
