// pi/index.ts - the board as a Pi extension (docs/pi.md): fleet counts in the
// footer status line, /board for the whole board in an overlay, and a, d, D
// and c filling the chat box with the selected row. Nothing is sent and no
// hold is written from here.

import { execFile } from "node:child_process";
import { accessSync, constants, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { decodeKittyPrintable, isKeyRelease, parseKey, type TUI, truncateToWidth } from "@earendil-works/pi-tui";
import { createApp } from "../lib/app.mjs";
import { parseArgs } from "../lib/args.mjs";
import { DEFER_DEFAULT_DAYS, localDate, plusDays } from "../lib/card.mjs";
import { keyAction, selectedRow } from "../lib/controller.mjs";
import { finishUpgrade } from "../lib/settings.mjs";
import { defaultViewStatePath } from "../lib/viewstate.mjs";

const PLUGIN_ID = "firstmate.board";
const STATUS_KEY = "fm-board";
const STATUS_TICK_MS = 5000;
const ARGS_ENV = "FM_BOARD_PI_ARGS";
const KEYS_NOTICE = "in Pi: a answer, d discard, D defer, c ask about a row (each fills the chat box; nothing is sent); q or esc closes";
const WRITES_OFF = "hold writes are off in Pi: a, d and D fill the chat box instead";
const PREFILL_KEYS = new Set(["a", "d", "D"]);
const COUNTED: [string, string][] = [
  ["needs", "call"],
  ["inflight", "underway"],
  ["mine", "my PRs"],
  ["toreview", "to review"],
];

type Segment = { text: string; style?: string };
type Board = { app: any; close: ((prefill?: string) => void) | null };

const STYLES: Record<string, (t: Theme, s: string) => string> = {
  title: (t, s) => t.inverse(t.bold(s)),
  border: (t, s) => t.fg("border", s),
  "border-focus": (t, s) => t.bold(t.fg("borderAccent", s)),
  colhead: (t, s) => t.bold(t.underline(s)),
  badge: (t, s) => t.fg("dim", s),
  heading: (t, s) => t.bold(s),
  selected: (t, s) => t.inverse(s),
  bad: (t, s) => t.fg("error", s),
  lost: (t, s) => t.fg("error", s),
  grey: (t, s) => t.fg("muted", s),
  empty: (t, s) => t.fg("dim", s),
  dim: (t, s) => t.fg("dim", s),
  notice: (t, s) => t.fg("warning", s),
  help: (t, s) => t.fg("warning", s),
  flag: (t, s) => t.fg("warning", s),
  drag: (t, s) => t.bold(t.fg("warning", s)),
};

export function toAnsi(theme: Theme, line: Segment[]): string {
  return line
    .map((seg) =>
      String(seg.style || "")
        .split(/\s+/)
        .filter((name) => STYLES[name])
        .reduceRight((text, name) => STYLES[name](theme, text), seg.text),
    )
    .join("");
}

export function boardKey(data: string): string | null {
  if (isKeyRelease(data)) return null;
  const printable = decodeKittyPrintable(data);
  if (printable) return printable;
  const id = parseKey(data);
  switch (id) {
    case undefined:
      return null;
    case "shift+tab":
      return "S-tab";
    case "pageUp":
      return "pageup";
    case "pageDown":
      return "pagedown";
    case "space":
      return " ";
    case "ctrl+c":
      return "ctrl-c";
    case "enter":
    case "tab":
    case "escape":
    case "backspace":
    case "up":
    case "down":
    case "left":
    case "right":
      return id;
    default:
      return id.length === 1 ? id : null;
  }
}

export function statusText(theme: Theme, model: any): string {
  const panes = new Map<string, any>(model.panes.map((p: any) => [p.id, p]));
  if (panes.get("needs")?.loading) return theme.fg("dim", "board: loading the fleet snapshot");
  const parts = COUNTED.map(([id, label]) => {
    const pane = panes.get(id);
    if (!pane || pane.loading) return theme.fg("dim", `- ${label}`);
    const n = pane.rows.filter((r: any) => !r.warning).length;
    return `${id === "needs" && n > 0 ? theme.fg("warning", String(n)) : String(n)} ${theme.fg("dim", label)}`;
  });
  const stale = model.meta.snapshotError ? ` ${theme.fg("error", "(snapshot failed)")}` : "";
  return `${theme.fg("dim", "board")} ${parts.join(theme.fg("dim", " | "))}${stale}`;
}

export function holdPrefill(action: any): string | null {
  const hold = action && action.row ? action.row.hold : null;
  if (!hold) return null;
  const who = hold.homeId && hold.homeId !== "main" ? `${hold.id} in ${hold.homeId}` : hold.id;
  switch (action.type) {
    case "accept-prompt":
      return `Answer for ${who}: `;
    case "discard-prompt":
      return `Discard the hold on ${who}: `;
    case "defer-prompt":
      return `Defer ${who} until ${plusDays(localDate(), DEFER_DEFAULT_DAYS)}: `;
    default:
      return null;
  }
}

export function rowPrefill(pane: any, row: any): string {
  return `About ${row.name} in ${pane.title}${row.url ? ` (${row.url})` : ""}: `;
}

function firstLine(text: string): string {
  return String(text || "").split("\n")[0].trim();
}

function pluginFmHome(env: NodeJS.ProcessEnv): string | null {
  if (!env.HERDR_PLUGIN_CONFIG_DIR) return null;
  try {
    return firstLine(readFileSync(join(env.HERDR_PLUGIN_CONFIG_DIR, "fm-home"), "utf8")) || null;
  } catch {
    return null;
  }
}

function pluginConfigDir(env: NodeJS.ProcessEnv, opts: any): Promise<string | null> {
  if (env.HERDR_PLUGIN_CONFIG_DIR) return Promise.resolve(env.HERDR_PLUGIN_CONFIG_DIR.replace(/\/+$/, ""));
  if (!opts.herdr) return Promise.resolve(null);
  const [cmd, ...pre] = opts.herdrCmd;
  return new Promise((resolve) => {
    execFile(cmd, [...pre, "plugin", "config-dir", PLUGIN_ID], { timeout: 5000 }, (err, stdout) => {
      resolve(err ? null : firstLine(stdout).replace(/\/+$/, "") || null);
    });
  });
}

export async function boardOptions(env: NodeJS.ProcessEnv): Promise<{ opts: any; problem: string | null }> {
  const opts = parseArgs((env[ARGS_ENV] || "").split(/\s+/).filter(Boolean), env);
  const fmHome = (opts.fmHome || pluginFmHome(env) || "").replace(/\/+$/, "");
  if (!fmHome) return { opts, problem: "FM_HOME is not set; start pi with FM_HOME=/path/to/firstmate (the directory holding bin/fm-fleet-snapshot.sh)" };
  try {
    accessSync(join(fmHome, "bin/fm-fleet-snapshot.sh"), constants.X_OK);
  } catch {
    return { opts, problem: `FM_HOME=${fmHome} has no executable bin/fm-fleet-snapshot.sh; is it a firstmate home?` };
  }
  const dir = await pluginConfigDir(env, opts);
  const fallback = defaultViewStatePath(env);
  const base = dir || (fallback ? dirname(fallback) : null);
  return {
    opts: {
      ...opts,
      fmHome,
      viewState: opts.viewState || (base ? join(base, "pi", "view-state.json") : null),
      config: opts.config || (dir ? join(dir, "config.json") : null),
      summaries: false,
      mouse: false,
      headless: false,
    },
    problem: null,
  };
}

class BoardScreen {
  private lines: Segment[][] = [];
  private cols = 0;
  private rows = 0;
  private rendering = false;

  constructor(
    private tui: TUI,
    private theme: Theme,
    private app: any,
    private onKey: (key: string) => void,
  ) {}

  size() {
    return { cols: this.cols || this.tui.terminal.columns, rows: this.rows || this.tui.terminal.rows };
  }

  draw(lines: Segment[][]) {
    this.lines = lines;
    if (!this.rendering) this.tui.requestRender();
  }

  suspended() {
    return false;
  }

  suspend() {}

  resume() {}

  destroy() {}

  render(width: number): string[] {
    const rows = this.tui.terminal.rows;
    if (width !== this.cols || rows !== this.rows) {
      this.cols = width;
      this.rows = rows;
      this.rendering = true;
      try {
        this.app.draw();
      } finally {
        this.rendering = false;
      }
    }
    return this.lines.map((line) => truncateToWidth(toAnsi(this.theme, line), width));
  }

  handleInput(data: string) {
    const key = boardKey(data);
    if (key) this.onKey(key);
  }

  invalidate() {}
}

function fillEditor(ctx: ExtensionCommandContext, text: string) {
  const current = ctx.ui.getEditorText();
  ctx.ui.setEditorText(current.trim() ? `${current.replace(/\s+$/, "")}\n${text}` : text);
}

export default function (pi: ExtensionAPI) {
  let board: Board | null = null;
  let problem: string | null = null;
  let statusTimer: ReturnType<typeof setInterval> | null = null;

  const onBoardKey = (key: string) => {
    if (!board || !board.close) return;
    const { app, close } = board;
    const view = app.view;
    const atTop = view.page === "board" && !view.prompt && !view.help;
    if (key === "escape" && atTop) return close();
    const summaryRow = view.page === "board" && !view.help && view.prompt && view.prompt.kind === "summary" ? view.prompt.row : null;
    if (PREFILL_KEYS.has(key) && (atTop || summaryRow)) {
      const text = holdPrefill(keyAction(app.model, view, key, summaryRow));
      if (text) return close(text);
    }
    if (key === "c" && atTop) {
      const row = selectedRow(app.model, view);
      if (row) return close(rowPrefill(app.model.panes[view.pane], row));
    }
    app.onKey(key);
  };

  const stopBoard = () => {
    if (statusTimer) clearInterval(statusTimer);
    statusTimer = null;
    if (!board) return;
    const { app, close } = board;
    board = null;
    if (close) close();
    app.stop();
  };

  pi.on("session_start", async (_event, ctx: ExtensionContext) => {
    if (ctx.mode !== "tui") return;
    stopBoard();
    try {
      const resolved = await boardOptions(process.env);
      problem = resolved.problem;
      if (problem) {
        ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("dim", "board: off (see /board)"));
        return;
      }
      const refuse = () => app.notice(WRITES_OFF, true);
      const app = createApp(resolved.opts, {
        quit: () => board?.close?.(),
        relaunch: () => app.notice("relaunch is not available inside Pi; restart pi instead", true),
        effects: {
          holdAccept: refuse,
          holdAnswer: refuse,
          holdDiscard: refuse,
          holdDefer: refuse,
          holdReason: refuse,
          viewFull: () => app.notice("the full document opens only in the standalone board; Pi has no pager hand-off yet", true),
          settingsUpgrade: () => {
            const s = app.view.settings;
            s.output.push("upgrades run from the standalone board, not from inside Pi");
            finishUpgrade(s, { code: null, signal: null, error: "not available inside Pi" });
            app.notice("upgrade is off inside Pi; run firstmate-tui upgrade in a terminal", true);
          },
        },
      });
      board = { app, close: null };
      app.start();
      const tick = () => {
        if (board && board.app === app) ctx.ui.setStatus(STATUS_KEY, statusText(ctx.ui.theme, board.close ? app.model : app.rebuild()));
      };
      tick();
      statusTimer = setInterval(tick, STATUS_TICK_MS);
    } catch (e) {
      problem = `board failed to start: ${e instanceof Error ? e.message : String(e)}`;
      ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("error", "board: failed to start (see /board)"));
    }
  });

  pi.on("session_shutdown", async (_event, ctx: ExtensionContext) => {
    stopBoard();
    if (ctx.mode === "tui") ctx.ui.setStatus(STATUS_KEY, undefined);
  });

  pi.registerCommand("board", {
    description: "Open the firstmate board; q or escape closes it",
    handler: async (_args, ctx) => {
      if (ctx.mode !== "tui") {
        ctx.ui.notify("/board needs the interactive terminal", "error");
        return;
      }
      if (!board) {
        ctx.ui.notify(problem || "the board is not running in this session", "error");
        return;
      }
      if (board.close) return;
      const current = board;
      const result = await ctx.ui.custom<{ prefill?: string } | undefined>(
        (tui, theme, _keybindings, done) => {
          current.close = (prefill) => done(prefill ? { prefill } : undefined);
          const screen = new BoardScreen(tui, theme, current.app, onBoardKey);
          current.app.attach(screen);
          current.app.notice(KEYS_NOTICE, false, 12000);
          return screen;
        },
        { overlay: true, overlayOptions: { width: "100%", maxHeight: "100%", anchor: "top-left" } },
      );
      current.app.detach();
      current.close = null;
      if (result && result.prefill) fillEditor(ctx, result.prefill);
    },
  });
}
