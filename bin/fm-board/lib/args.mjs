// lib/args.mjs - command-line parsing for index.mjs. The bash wrapper passes
// every flag through unchanged, so this is the single definition of the
// board's options.

export const USAGE = `usage: fm-board.sh [run] [options]
       fm-board.sh open  [options]      open the board in its own herdr pane
       fm-board.sh focus [options]      focus an already open board pane
       fm-board.sh --render-once [--fixture <json>] [--cols N] [--rows N] [options]

options:
  --home <path>          add a secondmate home (repeatable). Default: FM_HOME plus
                         every home listed in FM_HOME/data/secondmates.md
  --refresh <seconds>    full snapshot cadence (default 30)
  --prs                  also run fm-bearings-snapshot.sh --include-prs (about 8 s,
                         live GitHub) so Ready for review shows checks and review state
  --no-herdr             skip the herdr overlay and the socket subscription
  --render-once          print one frame to stdout and exit (test mode)
  --fixture <json>       with --render-once: render this facts file instead of live reads
  --cols N / --rows N    frame size for --render-once (default: terminal, else 120x40)
  --herdr-cmd <argv>     command prefix for herdr calls (default: $HERDR_BIN_PATH or herdr);
                         quoted string, split on whitespace
  --herdr-socket <path>  herdr control socket (default: HERDR_SOCKET_PATH or herdr status)
  --snapshot-timeout <s> kill a snapshot run after this many seconds (default 60)
  -h, --help             this text`;

export function parseArgs(argv, env = {}) {
  const opts = {
    command: 'run',
    fmHome: env.FM_HOME || null,
    homes: [],
    refresh: 30,
    prs: false,
    herdr: true,
    renderOnce: false,
    fixture: null,
    cols: null,
    rows: null,
    herdrCmd: null,
    herdrSocket: null,
    snapshotTimeout: 60,
    help: false,
  };
  const args = [...argv];
  if (args.length && !args[0].startsWith('-') && ['run', 'open', 'focus'].includes(args[0])) {
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
      case '--prs':
        opts.prs = true;
        break;
      case '--no-herdr':
        opts.herdr = false;
        break;
      case '--render-once':
        opts.renderOnce = true;
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
