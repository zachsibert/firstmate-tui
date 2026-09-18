// lib/upgrade.mjs - the two pieces of I/O behind the Settings page that are
// not the releases API: reading the install identity and running the upgrade.
//
// An install is <root>/bin/fm-board.sh plus <root>/install-record, the
// key=value file bin/install.sh writes (prefix, bin_dir, repo, version,
// installed_from); the running version is the "version" in
// <root>/bin/fm-board/package.json. <root> is the directory two levels above
// this package (the install prefix, or a checkout), or --install-root when a
// test points the page at a fake prefix. A root without a record is a
// checkout: the page shows the git pull hint and no upgrade actions.
//
// The upgrade itself is `bash <root>/bin/fm-board.sh upgrade --version <v>`
// (or --stable), spawned as an argv with piped stdout and stderr so each line
// lands on the page as it arrives. The launcher checks the record and execs
// the bin/install.sh that shipped with the copy, so download, verify and swap
// have one implementation and the board adds nothing to it. Nothing here
// writes a file.

import { spawn as nodeSpawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DEFAULT_REPO, versionKind } from './settings.mjs';

export function defaultInstallRoot() {
  return fileURLToPath(new URL('../../../', import.meta.url)).replace(/\/+$/, '');
}

// key=value lines; comment lines start with #.
export function parseInstallRecord(text) {
  const record = {};
  for (const raw of String(text).split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq <= 0) continue;
    record[line.slice(0, eq)] = line.slice(eq + 1);
  }
  return record;
}

export function readInstall(root) {
  const r = String(root).replace(/\/+$/, '');
  const pkgPath = `${r}/bin/fm-board/package.json`;
  const recordPath = `${r}/install-record`;
  let version = null;
  let error = null;
  try {
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));
    version = typeof pkg.version === 'string' && pkg.version ? pkg.version : null;
    if (!version) error = `${pkgPath}: no version field`;
  } catch (e) {
    error = `${pkgPath}: ${e.code === 'ENOENT' ? 'not found' : e.message}`;
  }
  let record = null;
  try {
    record = parseInstallRecord(readFileSync(recordPath, 'utf8'));
  } catch (e) {
    if (e.code !== 'ENOENT') error = error || `${recordPath}: ${e.message}`;
  }
  return {
    root: r,
    version,
    kind: versionKind(version),
    record,
    checkout: !record,
    git: existsSync(`${r}/.git`),
    launcher: `${r}/bin/fm-board.sh`,
    repo: record && record.repo ? record.repo : DEFAULT_REPO,
    error,
  };
}

// Run `bash <launcher> upgrade <args...>`, calling onLine(text) for every
// complete line of stdout or stderr in arrival order, and resolve with
// { code, signal, error } when the child has exited and both pipes are
// drained. Never rejects: a spawn failure is an error in the result.
export function runUpgrade({ launcher, args, onLine, spawn = nodeSpawn, env = process.env }) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn('bash', [launcher, 'upgrade', ...args], { stdio: ['ignore', 'pipe', 'pipe'], env });
    } catch (e) {
      resolve({ code: null, signal: null, error: e.message });
      return;
    }
    const rest = { out: '', err: '' };
    const consume = (which) => (chunk) => {
      rest[which] += chunk;
      const parts = rest[which].split('\n');
      rest[which] = parts.pop();
      for (const p of parts) onLine(p.replace(/\r$/, ''));
    };
    const flush = () => {
      for (const which of ['out', 'err']) {
        if (rest[which]) onLine(rest[which]);
        rest[which] = '';
      }
    };
    let settled = false;
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', consume('out'));
    child.stderr.on('data', consume('err'));
    child.on('error', (e) => {
      if (settled) return;
      settled = true;
      flush();
      resolve({ code: null, signal: null, error: e && e.code === 'ENOENT' ? 'bash not found' : e.message });
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      settled = true;
      flush();
      resolve({ code: code ?? null, signal: signal ?? null, error: null });
    });
  });
}
