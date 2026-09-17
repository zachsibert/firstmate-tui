// lib/split.mjs - the `f` toggle: put the firstmate pane beside the board, or
// move it back out to its own workspace. Shared by the board key (lib/app.mjs)
// and the wrapper subcommands split-firstmate / unsplit-firstmate /
// toggle-firstmate, which the herdr plugin actions firstmate.board.* run.
//
// The firstmate pane is found at press time, never recorded: the claude agent
// in `herdr agent list` whose cwd (or foreground cwd) is FM_HOME, else the
// agent whose terminal title contains "First mate" (the primary firstmate's
// title is "✳ First mate", scout report section 3.1). Nothing here ever calls
// pane close.
//
// herdr calls, in order (a fake herdr on PATH records the argv in tests):
//   agent list
//   pane get <board-pane>                      where the board is (tab, workspace)
//   split:   pane move <fm> --workspace <board-ws> --target-pane <board-pane>
//                      --split right --ratio 0.55      then agent focus <fm>
//   unsplit: pane move <fm> --new-workspace           then agent focus <board-pane>
// "Beside the board" means the same tab when both records name one, else the
// same workspace (the plugin route hosts the board as a tab in the captain's
// workspace, so a workspace match alone would be wrong there).

export const SPLIT_RATIO = '0.55';

function str(v) {
  return typeof v === 'string' ? v : '';
}

function stripSlash(p) {
  return str(p).replace(/\/+$/, '');
}

function isClaude(agent) {
  const kind = str(agent.agent || (agent.agent_session && agent.agent_session.agent)).toLowerCase();
  return kind === '' || kind.includes('claude');
}

// { paneId, workspaceId, tabId, how: 'cwd' | 'title', title } or null.
export function findFirstmatePane(agents, fmHome) {
  const list = Array.isArray(agents) ? agents.filter((a) => a && a.pane_id) : [];
  const home = stripSlash(fmHome);
  const pick = (a, how) => ({ paneId: a.pane_id, workspaceId: a.workspace_id || null, tabId: a.tab_id || null, how, title: str(a.terminal_title_stripped || a.terminal_title) });
  if (home) {
    const byCwd = list.filter((a) => isClaude(a) && (stripSlash(a.cwd) === home || stripSlash(a.foreground_cwd) === home));
    if (byCwd.length === 1) return pick(byCwd[0], 'cwd');
    if (byCwd.length > 1) {
      const titled = byCwd.find((a) => /first ?mate/i.test(str(a.terminal_title_stripped || a.terminal_title)));
      return pick(titled || byCwd[0], 'cwd');
    }
  }
  const byTitle = list.find((a) => /first ?mate/i.test(str(a.terminal_title_stripped || a.terminal_title)));
  return byTitle ? pick(byTitle, 'title') : null;
}

export function splitArgs(fmPane, boardWorkspace, boardPane) {
  return ['pane', 'move', fmPane, '--workspace', boardWorkspace, '--target-pane', boardPane, '--split', 'right', '--ratio', SPLIT_RATIO];
}

export function unsplitArgs(fmPane) {
  return ['pane', 'move', fmPane, '--new-workspace'];
}

// Is the firstmate pane already beside the board?
export function besideBoard(fm, board) {
  if (fm.tabId && board.tabId) return fm.tabId === board.tabId;
  return Boolean(fm.workspaceId && board.workspaceId && fm.workspaceId === board.workspaceId);
}

function agentsOf(result) {
  if (result && result.result && Array.isArray(result.result.agents)) return result.result.agents;
  if (result && Array.isArray(result.agents)) return result.agents;
  return [];
}

function paneOf(result) {
  const p = result && result.result && result.result.pane ? result.result.pane : result && result.pane ? result.pane : null;
  if (!p) return null;
  return { paneId: p.pane_id || null, workspaceId: p.workspace_id || null, tabId: p.tab_id || null };
}

// mode: 'toggle' | 'split' | 'unsplit'. client must offer cli(args, {json}).
// Resolves { action: 'split' | 'unsplit' | 'none', fmPane, message }; rejects
// with a message fit for a red footer notice when no firstmate pane is found
// or a herdr call fails.
export async function moveFirstmatePane({ client, fmHome, boardPane, mode = 'toggle' }) {
  if (!client) throw new Error('herdr is off (--no-herdr); cannot move panes');
  if (!boardPane) throw new Error('board pane unknown: run the board inside herdr (fm-board.sh open) or pass --board-pane');
  const agents = agentsOf(await client.cli(['agent', 'list']));
  const fm = findFirstmatePane(agents, fmHome);
  if (!fm) throw new Error(`no firstmate pane found: no claude agent with cwd ${fmHome || '(FM_HOME unset)'} and no pane titled "First mate"`);
  if (fm.paneId === boardPane) throw new Error(`the firstmate pane ${fm.paneId} is the board pane itself; nothing to move`);
  const board = paneOf(await client.cli(['pane', 'get', boardPane]));
  if (!board) throw new Error(`herdr pane get ${boardPane} returned no pane`);
  const beside = besideBoard(fm, board);
  if (mode === 'split' && beside) return { action: 'none', fmPane: fm.paneId, message: `firstmate pane ${fm.paneId} is already beside the board` };
  if (mode === 'unsplit' && !beside) return { action: 'none', fmPane: fm.paneId, message: `firstmate pane ${fm.paneId} is not beside the board` };
  const action = mode === 'toggle' ? (beside ? 'unsplit' : 'split') : mode;
  if (action === 'split') {
    if (!board.workspaceId) throw new Error(`herdr pane get ${boardPane} reported no workspace`);
    await client.cli(splitArgs(fm.paneId, board.workspaceId, boardPane), { json: false });
    await client.cli(['agent', 'focus', fm.paneId], { json: false });
    return { action, fmPane: fm.paneId, message: `firstmate pane ${fm.paneId} (${fm.how}) split right of the board; f moves it back` };
  }
  await client.cli(unsplitArgs(fm.paneId), { json: false });
  await client.cli(['agent', 'focus', boardPane], { json: false });
  return { action, fmPane: fm.paneId, message: `firstmate pane ${fm.paneId} moved to its own workspace; f brings it back` };
}
