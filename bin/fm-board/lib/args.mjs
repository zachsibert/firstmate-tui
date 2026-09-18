// lib/args.mjs - command-line parsing for index.mjs. The bash wrapper passes
// every flag through unchanged, so this is the single definition of the
// board's options.

export const USAGE = `usage: firstmate-tui [open] [options]    run the board in this terminal
       firstmate-tui open --detached [options]  open it in its own herdr pane
       firstmate-tui focus [options]     focus an already open board pane
       firstmate-tui --render-once [--fixture <json>] [--cols N] [--rows N] [options]

options:
  --home <path>          add a secondmate home (repeatable). Default: FM_HOME plus
                         every home listed in FM_HOME/data/secondmates.md
  --refresh <seconds>    refresh cadence (default 30): every tick runs the fleet snapshot
                         and then, unless --no-prs, the live GitHub PR fetch (one gh pr
                         list per candidate repository, all at once), so nothing on
                         screen is older than this plus the two steps; a tick that
                         lands while a refresh is still running is skipped
  --no-prs               skip the live GitHub PR fetch (gh pr list; fm-bearings-snapshot.sh
                         --include-prs when gh is not on PATH) so Ready for review shows
                         recorded PR URLs only, with the file-time age marked ~; --prs
                         is accepted and does nothing (it is the default)
  --no-herdr             skip the herdr overlay and the socket subscription
  --all-homes-needs      Needs you also lists every secondmate home's open decisions
                         (default: main home only; secondmate decisions flag their
                         In flight group instead)
  --opener-cmd <argv>    command that opens a URL in the browser (default: open on
                         macOS, xdg-open on Linux); quoted string, split on whitespace
  --viewer-cmd <argv>    command that shows a Findings report in the terminal (default:
                         glow -p when glow is on PATH, else $EDITOR, else vim, else
                         less); quoted string, split on whitespace; the path is appended
  --view-state <path>    where hidden rows and hidden panes are remembered (default:
                         $(herdr plugin config-dir firstmate.board)/view-state.json via
                         the wrapper, else $XDG_CONFIG_HOME/fm-board/view-state.json,
                         else ~/.config/fm-board/view-state.json; never inside FM_HOME)
  --curl-cmd <argv>      command the Settings page (.) fetches the GitHub releases API
                         with (default: curl); quoted string, split on whitespace. In
                         --render-once nothing is fetched without it
  --install-root <dir>   where the Settings page looks for bin/fm-board/package.json,
                         install-record and bin/fm-board.sh (default: the directory two
                         levels above this package: the install prefix, or the checkout;
                         test mode points it at a fake prefix)
  --render-once          print one frame to stdout and exit (test mode)
  --fixture <json>       with --render-once: render this facts file instead of live reads
  --cols N / --rows N    frame size for --render-once (default: terminal, else 120x40)
  --keys <list>          with --render-once: press these keys first (comma or space
                         separated, e.g. "tab,j,enter"); a PR open runs --opener-cmd
                         when given and is only reported in the footer otherwise
  --no-mouse             ignore the mouse and leave the terminal's own text selection
                         alone (default: click selects, double-click is enter, the
                         wheel scrolls)
  --mouse <list>         with --render-once: mouse events, applied in order with --keys
                         (comma or space separated): click:X,Y  dblclick:X,Y
                         tripleclick:X,Y  wheel:up:X,Y  wheel:down:X,Y, X and Y the
                         cell from 0 at the top-left; any other token is a key, so
                         "click:12,5 x" selects
                         a row and hides it
  --expand <all|ids>     with --render-once: expand these In flight groups (secondmate
                         ids, or all) before rendering
  --tags                 with --render-once: print the frame with its color tags
                         ({red-fg}...{/red-fg}) instead of plain text
  --headless             run the interactive refresh schedule with no terminal: nothing
                         is drawn and no key is read (test mode; stop it with a signal)
  --herdr-cmd <argv>     command prefix for herdr calls (default: $HERDR_BIN_PATH or herdr);
                         quoted string, split on whitespace
  --herdr-socket <path>  herdr control socket (default: HERDR_SOCKET_PATH or herdr status)
  --snapshot-timeout <s> kill a snapshot run after this many seconds (default 60)
  -h, --help             this text`;

export const COMMANDS = ['run', 'open', 'focus'];

// One --mouse token -> the mouse events it stands for (lib/controller.mjs
// mouseAction shape, without `time`), or null when the token is a key name.
// dblclick is two left clicks on the cell, which is what the pure double-click
// detection needs to see, and tripleclick three (a press landing inside the
// window a double-click already used); the driver stamps a token's events
// with one time.
export function parseMouseToken(token) {
  const m = /^(click|dblclick|tripleclick|wheel:(?:up|down)):(\d+),(\d+)$/.exec(token);
  if (!m) {
    // Something shaped like an event but not one of ours (rclick included: the
    // board binds nothing to the right button) is an error, not a key name.
    if (/^(click|dblclick|tripleclick|rclick|mclick|wheel)(:|$)/.test(token)) throw new Error(`--mouse: bad event "${token}" (want click:X,Y, dblclick:X,Y, tripleclick:X,Y, wheel:up:X,Y or wheel:down:X,Y)`);
    return null;
  }
  const x = Number(m[2]);
  const y = Number(m[3]);
  const down = () => ({ type: 'down', button: 'left', x, y });
  switch (m[1]) {
    case 'click':
      return [down()];
    case 'dblclick':
      return [down(), down()];
    case 'tripleclick':
      return [down(), down(), down()];
    default:
      return [{ type: 'wheel', dir: m[1].slice(6), x, y }];
  }
}

export function parseArgs(argv, env = {}) {
  const opts = {
    command: 'run',
    fmHome: env.FM_HOME || null,
    homes: [],
    refresh: 30,
    prs: true,
    herdr: true,
    renderOnce: false,
    headless: false,
    fixture: null,
    cols: null,
    rows: null,
    herdrCmd: null,
    herdrSocket: null,
    snapshotTimeout: 60,
    allHomesNeeds: false,
    openerCmd: null,
    viewerCmd: null,
    viewState: null,
    curlCmd: null,
    installRoot: null,
    tags: false,
    keys: [],
    mouse: true,
    // --keys and --mouse tokens in command-line order: [{ kind: 'key', key }]
    // and [{ kind: 'mouse', events }], so a test can click, then press.
    inputs: [],
    expand: [],
    help: false,
  };
  const args = [...argv];
  if (args.length && !args[0].startsWith('-') && COMMANDS.includes(args[0])) {
    opts.command = args.shift();
  }
  const need = (flag) => {
    if (!args.length || args[0].startsWith('--')) throw new Error(`${flag} needs a value`);
    return args.shift();
  };
  const num = (flag, raw, min) => {
    const n = Number(raw);
    if (!Number.isFinite(n) || n < min) throw new Error(`${flag} must be a number >= ${min}`);
    return n;
  };
  while (args.length) {
    const a = args.shift();
    switch (a) {
      case '--home':
        opts.homes.push(need(a));
        break;
      case '--fm-home':
        opts.fmHome = need(a);
        break;
      case '--refresh':
        opts.refresh = num(a, need(a), 5);
        break;
      case '--prs': // the default since the single refresh cadence; kept so old launch lines still work
        opts.prs = true;
        break;
      case '--no-prs':
        opts.prs = false;
        break;
      case '--no-herdr':
        opts.herdr = false;
        break;
      case '--render-once':
        opts.renderOnce = true;
        break;
      case '--headless':
        opts.headless = true;
        break;
      case '--fixture':
        opts.fixture = need(a);
        break;
      case '--cols':
        opts.cols = num(a, need(a), 1);
        break;
      case '--rows':
        opts.rows = num(a, need(a), 1);
        break;
      case '--herdr-cmd':
        opts.herdrCmd = need(a).split(/\s+/).filter(Boolean);
        break;
      case '--herdr-socket':
        opts.herdrSocket = need(a);
        break;
      case '--snapshot-timeout':
        opts.snapshotTimeout = num(a, need(a), 1);
        break;
      case '--all-homes-needs':
        opts.allHomesNeeds = true;
        break;
      case '--opener-cmd':
        opts.openerCmd = need(a).split(/\s+/).filter(Boolean);
        break;
      case '--viewer-cmd':
        opts.viewerCmd = need(a).split(/\s+/).filter(Boolean);
        break;
      case '--view-state':
        opts.viewState = need(a);
        break;
      case '--curl-cmd':
        opts.curlCmd = need(a).split(/\s+/).filter(Boolean);
        break;
      case '--install-root':
        opts.installRoot = need(a);
        break;
      case '--tags':
        opts.tags = true;
        break;
      case '--keys':
        for (const key of need(a).split(/[\s,]+/).filter(Boolean)) {
          opts.keys.push(key);
          opts.inputs.push({ kind: 'key', key });
        }
        break;
      case '--no-mouse':
        opts.mouse = false;
        break;
      case '--mouse':
        // Tokens split on commas and spaces, except the comma inside an
        // event's X,Y: "click:12,5,1,tab" is a click, then the keys 1 and tab.
        // Anything shaped like an event keeps its X,Y so parseMouseToken can
        // name an unsupported one whole ("rclick:12,5", not "rclick:12").
        for (const token of need(a).match(/[a-z]+(?::[a-z]+)*:\d+,\d+|[^\s,]+/g) || []) {
          const events = parseMouseToken(token);
          if (events) opts.inputs.push({ kind: 'mouse', events });
          else {
            opts.keys.push(token);
            opts.inputs.push({ kind: 'key', key: token });
          }
        }
        break;
      case '--expand':
        opts.expand.push(...need(a).split(/[\s,]+/).filter(Boolean));
        break;
      case '-h':
      case '--help':
        opts.help = true;
        break;
      default:
        throw new Error(`unknown option ${a}`);
    }
  }
  if (!opts.herdrCmd) opts.herdrCmd = [env.HERDR_BIN_PATH || 'herdr'];
  return opts;
}
