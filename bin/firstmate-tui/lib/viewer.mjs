// lib/viewer.mjs - show a Findings report in the terminal. `enter` on a
// Findings row hands the report path to a viewer that takes over the terminal
// (the app suspends the blessed screen first, see lib/app.mjs) and the board
// comes back when the viewer exits.
//
// Viewer chain, first match wins:
//   --viewer-cmd <argv>   explicit override (tests inject a fake that records argv)
//   glow -p               when glow is on PATH (the captain's markdown pager)
//   $EDITOR               when set (split on whitespace, so "code --wait" works)
//   vim                   when on PATH
//   less                  last resort
// The path is appended as one argv element and the viewer is spawned without a
// shell, so a report path can carry no shell metacharacters into the command.
// Nothing here writes a file.

import { spawn as nodeSpawn } from 'node:child_process';
import { accessSync, constants, statSync } from 'node:fs';

function isExecutableFile(path) {
  try {
    accessSync(path, constants.X_OK);
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

// Absolute path of `bin` on env.PATH, or null. A name with a slash is checked
// as given.
export function whichOnPath(bin, env = process.env) {
  if (!bin) return null;
  if (bin.includes('/')) return isExecutableFile(bin) ? bin : null;
  for (const dir of String(env.PATH || '').split(':')) {
    if (!dir) continue;
    const candidate = `${dir.replace(/\/+$/, '')}/${bin}`;
    if (isExecutableFile(candidate)) return candidate;
  }
  return null;
}

// { argv, source } where source names the rung of the chain that matched. A
// binary found on PATH is returned as the absolute path that was found, so a
// notice can say exactly which glow or vim will run.
export function resolveViewer({ cmd = null, env = process.env } = {}) {
  if (Array.isArray(cmd) && cmd.length) return { argv: [...cmd], source: 'viewer-cmd' };
  const glow = whichOnPath('glow', env);
  if (glow) return { argv: [glow, '-p'], source: 'glow' };
  const editor = String(env.EDITOR || '')
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  if (editor.length) return { argv: editor, source: 'EDITOR' };
  const vim = whichOnPath('vim', env);
  if (vim) return { argv: [vim], source: 'vim' };
  return { argv: ['less'], source: 'less' };
}

// Run `argv... path` with the terminal (stdio inherited) and resolve with the
// exit code once the viewer has quit. Rejects when the viewer cannot start.
// The caller owns the terminal state around this call.
export function runViewer(path, { argv, spawn = nodeSpawn, env = process.env, stdio = 'inherit' } = {}) {
  if (!path || typeof path !== 'string') return Promise.reject(new Error('no report path'));
  if (!Array.isArray(argv) || !argv.length) return Promise.reject(new Error('no viewer command'));
  return new Promise((resolve, reject) => {
    const [bin, ...prefix] = argv;
    let child;
    try {
      child = spawn(bin, [...prefix, path], { stdio, env });
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
    child.on('exit', (code, signal) => {
      if (settled) return;
      settled = true;
      resolve({ code: code ?? null, signal: signal ?? null });
    });
  });
}
