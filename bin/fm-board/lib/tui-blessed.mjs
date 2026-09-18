// lib/tui-blessed.mjs - the ONLY module that imports neo-blessed. It exposes a
// tiny screen contract so the terminal library can be swapped without touching
// the model, layout or renderer:
//   const screen = await createScreen({ onKey, onMouse, onResize, mouse })
//   screen.size()        -> { cols, rows }
//   screen.draw(lines)   -> paint one rendered frame (segments from render.mjs)
//   screen.suspend()     -> leave the alternate screen and hand the terminal to
//                           a child process (the report viewer); input is
//                           paused and raw mode is off until resume()
//   screen.resume()      -> take the terminal back and repaint everything
//   screen.destroy()     -> restore the terminal
// Keys are normalized to short names: j k h l o x X H f 0-9 up down left right
// tab S-tab enter r ? q escape ctrl-c. One key press must reach onKey once:
// the library reports the Enter key (\r) as two keypress events, and
// normalizeKey() keeps one of them (see there).
//
// Mouse: with `mouse` true the screen listens for the library's mouse events,
// which is what turns the terminal's mouse reporting on (and off again on
// destroy, and around suspend/resume for the viewer, both inside the library).
// normalizeMouse() turns each event into the plain object
// lib/controller.mjs reads: { type: 'down' | 'up' | 'wheel', button, x, y,
// dir, time }, cells from 0 at the top-left. Motion and drag events are
// dropped; nothing here decides what a click means. With `mouse` false no
// listener is added, so the terminal keeps its own click and text selection.
//
// A segment style is one or more space-separated names from STYLE_TAGS
// ("selected lost" is an inverse row whose cell is also red); toTags() opens
// them in order and closes them in reverse.

const STYLE_TAGS = {
  title: ['{bold}{black-fg}{white-bg}', '{/white-bg}{/black-fg}{/bold}'],
  border: ['{blue-fg}', '{/blue-fg}'],
  'border-focus': ['{bold}{cyan-fg}', '{/cyan-fg}{/bold}'],
  colhead: ['{bold}{underline}', '{/underline}{/bold}'],
  badge: ['{grey-fg}', '{/grey-fg}'], // the [n] toggle key before a pane title
  heading: ['{bold}', '{/bold}'], // the landing page's one heading line
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

// One keypress event to one key name, or null for an event the board ignores.
// The Enter key arrives twice: neo-blessed 0.2.0 names a \r keypress 'return'
// and, before delivering it, re-emits a copy named 'enter' (lib/program.js,
// the input keypress listener), so one press is the two events
// { name: 'enter', sequence: '\r' } and { name: 'return', sequence: '\r' }.
// Only the 'enter' event counts here; 'return' is dropped, or every Enter
// would act twice (on the Settings page the second one cancelled the
// confirmation the first had just opened). A \n keypress (ctrl-j) is named
// 'linefeed' by the library and stays unbound.
export function normalizeKey(ch, key) {
  const name = key && key.name;
  if (key && key.ctrl && name === 'c') return 'ctrl-c';
  if (name === 'tab') return key.shift ? 'S-tab' : 'tab';
  if (name === 'enter') return 'enter';
  if (name === 'return') return null;
  if (name === 'up' || name === 'down' || name === 'left' || name === 'right' || name === 'escape' || name === 'pageup' || name === 'pagedown') return name;
  if (name === 'backtab') return 'S-tab';
  if (ch && ch.length === 1 && ch >= ' ') return ch;
  return name || null;
}

// One terminal mouse report in each of the encodings the library enables:
// X10/VT200 (ESC [ M plus three cells), SGR (ESC [ < b;x;y M or m) and urxvt
// (ESC [ b;x;y M).
const MOUSE_SEQUENCES = /\x1b\[M[\s\S]{3}|\x1b\[<\d+;\d+;\d+[mM]|\x1b\[\d+;\d+;\d+M/g;

export function normalizeMouse(data) {
  if (!data || !Number.isInteger(data.x) || !Number.isInteger(data.y)) return null;
  const button = data.button === 'left' || data.button === 'right' || data.button === 'middle' ? data.button : null;
  switch (data.action) {
    case 'mousedown':
      return button ? { type: 'down', button, x: data.x, y: data.y } : null;
    case 'mouseup':
      return { type: 'up', button: button || 'left', x: data.x, y: data.y };
    case 'wheelup':
      return { type: 'wheel', dir: 'up', x: data.x, y: data.y };
    case 'wheeldown':
      return { type: 'wheel', dir: 'down', x: data.x, y: data.y };
    default:
      return null; // mousemove and drags are not the board's
  }
}

export async function createScreen({ onKey, onMouse, onResize, mouse = false, title = 'firstmate-tui' }) {
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
  // Adding the listener is what enables mouse reporting (screen._listenMouse
  // calls program.enableMouse, verified in neo-blessed 0.2.0
  // lib/widgets/screen.js); without it the terminal never hears about it.
  if (mouse && onMouse) {
    // The library parses one mouse sequence per input chunk (program.js
    // _bindMouse anchors its match at the start of the chunk, verified in
    // neo-blessed 0.2.0), and while the board is busy drawing the frame for
    // one press the terminal can deliver that press's release and the next
    // press in a single read, which would lose the second click of a
    // double-click. Hand the library one sequence at a time.
    const program = screen.program;
    const bindOne = program._bindMouse.bind(program);
    program._bindMouse = (s, buf) => {
      const parts = typeof s === 'string' ? s.match(MOUSE_SEQUENCES) : null;
      if (!parts || parts.length < 2) return bindOne(s, buf);
      for (const part of parts) bindOne(part, buf);
      return undefined;
    };
    screen.on('mouse', (data) => {
      if (suspended) return;
      const ev = normalizeMouse(data);
      if (ev) onMouse({ ...ev, time: Date.now() });
    });
  }
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
