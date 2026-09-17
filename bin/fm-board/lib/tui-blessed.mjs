// lib/tui-blessed.mjs - the ONLY module that imports neo-blessed. It exposes a
// tiny screen contract so the terminal library can be swapped without touching
// the model, layout or renderer:
//   const screen = await createScreen({ onKey, onResize })
//   screen.size()        -> { cols, rows }
//   screen.draw(lines)   -> paint one rendered frame (segments from render.mjs)
//   screen.suspend()     -> leave the alternate screen and hand the terminal to
//                           a child process (the report viewer); input is
//                           paused and raw mode is off until resume()
//   screen.resume()      -> take the terminal back and repaint everything
//   screen.destroy()     -> restore the terminal
// Keys are normalized to short names: j k h l o x X H f 0-9 up down left right
// tab S-tab enter r ? q escape ctrl-c.
//
// A segment style is one or more space-separated names from STYLE_TAGS
// ("selected lost" is an inverse row whose cell is also red); toTags() opens
// them in order and closes them in reverse.

const STYLE_TAGS = {
  title: ['{bold}{black-fg}{white-bg}', '{/white-bg}{/black-fg}{/bold}'],
  border: ['{blue-fg}', '{/blue-fg}'],
  'border-focus': ['{bold}{cyan-fg}', '{/cyan-fg}{/bold}'],
  colhead: ['{bold}{underline}', '{/underline}{/bold}'],
  selected: ['{inverse}', '{/inverse}'],
  bad: ['{red-fg}', '{/red-fg}'],
  lost: ['{red-fg}', '{/red-fg}'],
  grey: ['{grey-fg}', '{/grey-fg}'],
  empty: ['{blue-fg}', '{/blue-fg}'],
  dim: ['{blue-fg}', '{/blue-fg}'],
  notice: ['{yellow-fg}', '{/yellow-fg}'],
  help: ['{yellow-fg}', '{/yellow-fg}'],
  flag: ['{yellow-fg}', '{/yellow-fg}'],
  row: ['', ''],
};

function escapeTags(text) {
  return String(text).replace(/\{/g, '{open}').replace(/\}/g, '{close}');
}

function tagsFor(style) {
  const names = String(style || 'row')
    .split(/\s+/)
    .filter((n) => STYLE_TAGS[n]);
  if (!names.length) return STYLE_TAGS.row;
  const open = names.map((n) => STYLE_TAGS[n][0]).join('');
  const close = names
    .slice()
    .reverse()
    .map((n) => STYLE_TAGS[n][1])
    .join('');
  return [open, close];
}

export function toTags(lines) {
  return lines
    .map((segments) =>
      segments
        .map((s) => {
          const [open, close] = tagsFor(s.style);
          return `${open}${escapeTags(s.text)}${close}`;
        })
        .join(''),
    )
    .join('\n');
}

export function normalizeKey(ch, key) {
  const name = key && key.name;
  if (key && key.ctrl && name === 'c') return 'ctrl-c';
  if (name === 'tab') return key.shift ? 'S-tab' : 'tab';
  if (name === 'enter' || name === 'return') return 'enter';
  if (name === 'up' || name === 'down' || name === 'left' || name === 'right' || name === 'escape' || name === 'pageup' || name === 'pagedown') return name;
  if (name === 'backtab') return 'S-tab';
  if (ch && ch.length === 1 && ch >= ' ') return ch;
  return name || null;
}

export async function createScreen({ onKey, onResize, title = 'fm-board' }) {
  const blessed = (await import('neo-blessed')).default;
  const screen = blessed.screen({
    smartCSR: true,
    fullUnicode: true,
    title,
    autoPadding: false,
    warnings: false,
    // Inside a multiplexer or herdr pane, a screen-less TERM would make blessed
    // guess badly; xterm-256color is what those hosts emulate.
    terminal: process.env.TERM && process.env.TERM !== 'dumb' ? process.env.TERM : 'xterm-256color',
  });
  const box = blessed.box({ parent: screen, top: 0, left: 0, width: '100%', height: '100%', tags: true, wrap: false, scrollable: false });
  let suspended = false;
  let resumeProgram = null;
  screen.on('keypress', (ch, key) => {
    if (suspended) return;
    const k = normalizeKey(ch, key);
    if (k) onKey(k);
  });
  screen.on('resize', () => {
    if (!suspended) onResize({ cols: screen.width, rows: screen.height });
  });
  return {
    size: () => ({ cols: screen.width, rows: screen.height }),
    draw(lines) {
      if (suspended) return;
      box.setContent(toTags(lines));
      screen.render();
    },
    suspended: () => suspended,
    // program.pause() saves the cursor, returns to the normal buffer, shows
    // the cursor, turns raw mode off and pauses stdin, and hands back the
    // function that undoes all of it (verified in neo-blessed 0.2.0
    // lib/program.js). Output writes are swallowed meanwhile, so a stray
    // draw() cannot paint over the viewer.
    suspend() {
      if (suspended) return;
      suspended = true;
      resumeProgram = screen.program.pause();
    },
    resume() {
      if (!suspended) return;
      const fn = resumeProgram;
      resumeProgram = null;
      if (fn) fn();
      suspended = false;
      // The viewer may have left keypad or cursor modes behind: re-enter ours
      // and repaint every cell (alloc() marks the whole screen dirty).
      try {
        screen.program.put.keypad_xmit();
      } catch {
        // terminal without a keypad string
      }
      screen.program.hideCursor();
      screen.alloc();
      screen.render();
    },
    destroy() {
      try {
        if (resumeProgram) resumeProgram();
        screen.destroy();
      } catch {
        // already gone
      }
    },
  };
}
