// lib/identity.mjs - who the captain is on GitHub, pure. The two PR panes
// are built around one login: My PRs lists what that login authored and To
// review what it was asked to review. The login comes from the first rung
// that answers:
//   config   identity.github_login in the config file (lib/config.mjs)
//   gh       `gh api user --jq .login`, the account gh is logged in as (one
//            call at startup, cached for the session; lib/sources.mjs runs it)
//   git      `git config --get github.user`
//   unknown  nothing answered: both PR panes show one row pointing at the
//            Settings page and fetch nothing
// It is never derived from user.name or user.email: neither is a GitHub
// login. The result is { login, source, reason } with source one of the four
// words above; an unknown identity carries each rung's failure in `reason`
// so the Settings page can say what was tried.

export const IDENTITY_SOURCES = ['config', 'gh', 'git', 'unknown'];

// The human words for a source, as the Settings page prints them.
export const SOURCE_WORDS = { config: 'config', gh: 'gh api user', git: 'git config github.user', fixture: 'fixture', unknown: 'unknown' };

// A login as GitHub accepts it: letters, digits and single hyphens, at most
// 39 characters. Anything else (an email, a display name, an empty answer)
// is refused, so a rung that answers junk is a failed rung.
export function validLogin(value) {
  const v = typeof value === 'string' ? value.trim() : '';
  return /^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/.test(v) ? v : null;
}

// rungs: { config: string | null, gh: { value, error } | null, git: { value,
// error } | null }. A null rung was not asked (for example gh under --no-prs),
// and its reason says so.
export function resolveIdentity({ config = null, gh = null, git = null } = {}) {
  const reasons = [];
  const fromConfig = validLogin(config);
  if (fromConfig) return { login: fromConfig, source: 'config', reason: null };
  reasons.push(config ? `config: "${config}" is not a GitHub login` : 'config: identity.github_login not set');
  for (const [source, rung] of [
    ['gh', gh],
    ['git', git],
  ]) {
    if (!rung) {
      reasons.push(`${source}: not asked`);
      continue;
    }
    if (rung.error) {
      reasons.push(`${source}: ${rung.error}`);
      continue;
    }
    const login = validLogin(rung.value);
    if (login) return { login, source, reason: null };
    reasons.push(rung.value && String(rung.value).trim() ? `${source}: "${String(rung.value).trim()}" is not a GitHub login` : `${source}: ${source === 'git' ? 'github.user not set' : 'no login in the answer'}`);
  }
  return { login: null, source: 'unknown', reason: reasons.join('; ') };
}

export function identityKnown(identity) {
  return Boolean(identity && identity.login);
}

// The one line the Settings page shows for the identity.
export function describeIdentity(identity, configPath) {
  if (identityKnown(identity)) return `${identity.login}  (from ${SOURCE_WORDS[identity.source] || identity.source})`;
  return `identity unknown: set identity.github_login in ${configPath || 'the config file'}, or run gh auth login`;
}
