// lib/herdr.mjs - the board's herdr client: CLI calls for bootstrap and focus,
// plus one long-lived newline-JSON subscription on the control socket.
//
// Wire format (verified on herdr 0.8.2 / protocol 20, same as firstmate's
// bin/backends/herdr-eventwait.py):
//   request : {"id":..,"method":"events.subscribe","params":{"subscriptions":[
//              {"type":"pane.updated"}, {"type":"pane.closed"},
//              {"type":"pane.agent_status_changed","pane_id":P}, ...]}}\n
//   ack     : {"id":..,"result":{"type":"subscription_started"}}\n
//   stream  : {"event":"pane.agent_status_changed","data":{"pane_id",..,"agent_status",..}}\n
//             {"event":"pane.updated","data":{"pane":{PaneInfo}}}\n
// Event names are normalized dot -> underscore so either spelling matches.

import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { createConnection } from 'node:net';

const CLI_TIMEOUT_MS = 10000;
const RECONNECT_MIN_MS = 2000;
const RECONNECT_MAX_MS = 30000;

export function normalizeEventName(name) {
  return String(name || '').replace(/\./g, '_');
}

// Apply one stream event to an agents map (pane id -> { agent_status, title,
// workspace_id }). Returns the affected pane id or null. Pure, so the fixture
// tests and the live client share it.
export function applyEvent(agents, event) {
  const type = normalizeEventName(event && event.event);
  const data = (event && event.data) || {};
  if (type === 'pane_agent_status_changed' && data.pane_id) {
    const cur = agents[data.pane_id] || {};
    agents[data.pane_id] = { ...cur, agent_status: data.agent_status || 'unknown', title: data.title ?? cur.title ?? null, workspace_id: data.workspace_id || cur.workspace_id || null };
    return data.pane_id;
  }
  if (type === 'pane_updated' && data.pane && data.pane.pane_id) {
    const p = data.pane;
    const cur = agents[p.pane_id] || {};
    agents[p.pane_id] = { ...cur, agent_status: p.agent_status || cur.agent_status || 'unknown', title: p.terminal_title_stripped ?? p.title ?? cur.title ?? null, workspace_id: p.workspace_id || cur.workspace_id || null };
    return p.pane_id;
  }
  if (type === 'pane_closed' && data.pane_id) {
    delete agents[data.pane_id];
    return data.pane_id;
  }
  return null;
}

// Build the agents map from `herdr api snapshot` (panes first, agents on top
// so agent records win) or from `herdr agent list`.
export function agentsFromSnapshot(result) {
  const agents = {};
  const snap = result && result.result && result.result.snapshot ? result.result.snapshot : result && result.snapshot ? result.snapshot : null;
  if (snap) {
    for (const p of Array.isArray(snap.panes) ? snap.panes : []) {
      if (p.pane_id) agents[p.pane_id] = { agent_status: p.agent_status || 'unknown', title: p.terminal_title_stripped ?? null, workspace_id: p.workspace_id || null };
    }
    for (const a of Array.isArray(snap.agents) ? snap.agents : []) {
      if (a.pane_id) agents[a.pane_id] = { agent_status: a.agent_status || 'unknown', title: a.terminal_title_stripped ?? a.title ?? null, workspace_id: a.workspace_id || null };
    }
    return agents;
  }
  const list = result && result.result && Array.isArray(result.result.agents) ? result.result.agents : Array.isArray(result && result.agents) ? result.agents : [];
  for (const a of list) {
    if (a.pane_id) agents[a.pane_id] = { agent_status: a.agent_status || 'unknown', title: a.terminal_title_stripped ?? a.title ?? null, workspace_id: a.workspace_id || null };
  }
  return agents;
}

export class HerdrClient extends EventEmitter {
  constructor({ cmd, socketPath, env = process.env }) {
    super();
    this.cmd = Array.isArray(cmd) && cmd.length ? cmd : ['herdr'];
    this.customCmd = Boolean(this.cmd.length > 1 || (this.cmd[0] !== 'herdr' && this.cmd[0] !== env.HERDR_BIN_PATH));
    this.socketPath = socketPath || null;
    this.env = env;
    this.agents = {};
    this.state = 'off';
    this.detail = '';
    this.panes = new Set();
    this.filterless = false;
    this.socket = null;
    this.reconnectMs = RECONNECT_MIN_MS;
    this.reconnectTimer = null;
    this.closed = false;
  }

  setState(state, detail = '') {
    if (this.state === state && this.detail === detail) return;
    this.state = state;
    this.detail = detail;
    this.emit('state', state, detail);
  }

  // Run `herdr <args>` (through the configured prefix) and parse JSON stdout.
  cli(args, { json = true } = {}) {
    return new Promise((resolve, reject) => {
      const [bin, ...prefix] = this.cmd;
      const child = spawn(bin, [...prefix, ...args], { env: this.env, stdio: ['ignore', 'pipe', 'pipe'] });
      let out = '';
      let err = '';
      let done = false;
      const timer = setTimeout(() => {
        if (done) return;
        done = true;
        child.kill('SIGKILL');
        reject(new Error(`herdr ${args.join(' ')} timed out`));
      }, CLI_TIMEOUT_MS);
      child.stdout.on('data', (d) => (out += d));
      child.stderr.on('data', (d) => (err += d));
      child.on('error', (e) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        reject(new Error(`cannot run ${bin}: ${e.code === 'ENOENT' ? 'not found' : e.message}`));
      });
      child.on('close', (code) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        if (code !== 0) {
          reject(new Error(`herdr ${args.join(' ')} failed: ${(err || out).trim().split('\n').slice(-1)[0] || `exit ${code}`}`));
          return;
        }
        if (!json) {
          resolve(out);
          return;
        }
        try {
          resolve(JSON.parse(out));
        } catch (e) {
          reject(new Error(`herdr ${args.join(' ')} returned bad JSON: ${e.message}`));
        }
      });
    });
  }

  async resolveSocket() {
    if (this.socketPath) return this.socketPath;
    // Inside a herdr pane the env points at the captain's session socket; a
    // custom command prefix (for example a lab helper) targets another session,
    // so ask that session where its socket is instead.
    if (!this.customCmd && this.env.HERDR_SOCKET_PATH) {
      this.socketPath = this.env.HERDR_SOCKET_PATH;
      return this.socketPath;
    }
    const status = await this.cli(['status', '--json']);
    const server = status && status.server ? status.server : {};
    const path = server.socket || server.socket_path || (status.socket && status.socket.path) || null;
    if (!path) throw new Error('herdr status did not report a socket path');
    this.socketPath = path;
    return path;
  }

  async bootstrap() {
    try {
      const snap = await this.cli(['api', 'snapshot']);
      this.agents = agentsFromSnapshot(snap);
      return true;
    } catch (e) {
      try {
        const list = await this.cli(['agent', 'list']);
        this.agents = agentsFromSnapshot(list);
        return true;
      } catch (e2) {
        this.setState('unavailable', e2.message.replace(/^herdr /, '').slice(0, 60));
        return false;
      }
    }
  }

  // Track the pane ids the board knows; resubscribe when the set changes.
  setPanes(ids) {
    const next = new Set(ids.filter(Boolean));
    const same = next.size === this.panes.size && [...next].every((p) => this.panes.has(p));
    this.panes = next;
    if (!same && this.socket && this.state === 'connected') {
      this.socket.destroy();
    }
  }

  // pane.updated already carries agent_status for every pane, so the per-pane
  // agent_status_changed filters are an optimization for the panes this
  // server knows. A pane id from another session (or one that closed since
  // the bootstrap) makes the server reject the whole request, so only panes
  // present in the bootstrap map are named, and after one rejection the
  // client falls back to the unfiltered subscription.
  subscriptions() {
    const subs = [{ type: 'pane.updated' }, { type: 'pane.closed' }];
    if (this.filterless) return subs;
    for (const p of this.panes) {
      if (this.agents[p]) subs.push({ type: 'pane.agent_status_changed', pane_id: p });
    }
    return subs;
  }

  async connect() {
    if (this.closed) return;
    let path;
    try {
      path = await this.resolveSocket();
    } catch (e) {
      this.setState('unavailable', e.message.slice(0, 60));
      this.scheduleReconnect();
      return;
    }
    this.setState('connecting');
    let buf = '';
    let acked = false;
    const sock = createConnection(path);
    this.socket = sock;
    sock.setEncoding('utf8');
    sock.on('connect', () => {
      sock.write(`${JSON.stringify({ id: 'fm-board-sub', method: 'events.subscribe', params: { subscriptions: this.subscriptions() } })}\n`);
    });
    sock.on('data', (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const lineText = buf.slice(0, i);
        buf = buf.slice(i + 1);
        if (!lineText.trim()) continue;
        let msg;
        try {
          msg = JSON.parse(lineText);
        } catch {
          continue;
        }
        if (!acked) {
          if (msg.result && msg.result.type === 'subscription_started') {
            acked = true;
            this.reconnectMs = RECONNECT_MIN_MS;
            this.setState('connected');
          } else if (msg.error) {
            const why = String(msg.error.message || msg.error).slice(0, 60);
            if (!this.filterless) {
              // Retry once without per-pane filters (see subscriptions()).
              this.filterless = true;
              this.reconnectMs = RECONNECT_MIN_MS;
              this.setState('connecting', why);
            } else {
              this.setState('disconnected', why);
            }
            sock.destroy();
          }
          continue;
        }
        if (msg.event) {
          const paneId = applyEvent(this.agents, msg);
          this.emit('event', { type: normalizeEventName(msg.event), paneId, data: msg.data });
        }
      }
    });
    const onDown = (why) => {
      if (this.socket !== sock) return;
      this.socket = null;
      if (!this.closed) {
        this.setState('disconnected', why);
        this.scheduleReconnect();
      }
    };
    sock.on('error', (e) => onDown(e.code || e.message));
    sock.on('close', () => onDown(this.detail || 'closed'));
  }

  scheduleReconnect() {
    if (this.closed || this.reconnectTimer) return;
    const delay = this.reconnectMs;
    this.reconnectMs = Math.min(RECONNECT_MAX_MS, this.reconnectMs * 2);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
    this.reconnectTimer.unref?.();
  }

  async focus(paneId) {
    await this.cli(['agent', 'focus', paneId], { json: false });
  }

  close() {
    this.closed = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    if (this.socket) this.socket.destroy();
    this.socket = null;
  }
}
