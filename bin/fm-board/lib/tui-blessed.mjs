// lib/tui-blessed.mjs - the ONLY module that imports neo-blessed. It exposes a
// tiny screen contract so the terminal library can be swapped without touching
// the model, layout or renderer:
//   const screen = await createScreen({ onKey, onResize })
//   screen.size()        -> { cols, rows }
//   screen.draw(lines)   -> paint one rendered frame (segments from render.mjs)
//   screen.destroy()     -> restore the terminal
// Keys are normalized to short names: j k up down tab S-tab enter r ? q escape ctrl-c.

const STYLE_TAGS = {
  title: ['{bold}{black-fg}{white-bg}', '{/white-bg}{/black-fg}{/bold}'],
  border: ['{blue-fg}', '{/blue-fg}'],
  'border-focus': ['{bold}{cyan-fg}', '{/cyan-fg}{/bold}'],
  colhead: ['{bold}{underline}', '{/underline}{/bold}'],
  selected: ['{inverse}', '{/inverse}'],
  bad: ['{red-fg}', '{/red-fg}'],
  empty: ['{blue-fg}', '{/blue-fg}'],
  dim: ['{blue-fg}', '{/blue-fg}'],
  notice: ['{yellow-fg}', '{/yellow-fg}'],
  help: ['{yellow-fg}', '{/yellow-fg}'],
  row: ['', ''],
};

function escapeTags(text) {
  return String(text).replace(/\{/g, '{open}').replace(/\}/g, '{close}');
}

export function toTags(lines) {
  return lines
    .map((segments) =>
      segments
        .map((s) => {
          const [open, close] = STYLE_TAGS[s.style] || STYLE_TAGS.row;
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
  if (name === 'up' || name === 'down' || name === 'escape' || name === 'pageup' || name === 'pagedown') return name;
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
  screen.on('keypress', (ch, key) => {
    const k = normalizeKey(ch, key);
    if (k) onKey(k);
  });
  screen.on('resize', () => onResize({ cols: screen.width, rows: screen.height }));
  return {
    size: () => ({ cols: screen.width, rows: screen.height }),
    draw(lines) {
      box.setContent(toTags(lines));
      screen.render();
    },
    destroy() {
      try {
        screen.destroy();
      } catch {
        // already gone
      }
    },
  };
}
