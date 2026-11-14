// OpenUsage's data, seeded for the Exact rewrite experiment. The view
// (app.contract) asks; this file answers. Provider sign-ins, the Keychain and
// real usage APIs are outside the experiment: accounts and metrics ship
// seeded, and mutations edit them in memory.
import type { Answer, Result, Sources } from './app.contract.d.ts';

export const grants = '';

type Metric = {
  id: string;
  label: string;
  kind: 'limit' | 'money' | 'value' | 'resets';
  pctLeft: number; // remaining fraction for limit/money bars and rings; -1 else
  resets: number;
  resetsMax: number;
  paceAt: number; // where an even burn would be now, 0..1; -1 none
  amountLeft: string;
  amountUsed: string;
  resetInMs: number; // -1 when the metric does not reset
  status: 'ok' | 'warning' | 'critical' | 'usedup' | 'plain';
  pinned: boolean;
  hidden: boolean;
  burningFast: boolean;
};
type Account = {
  id: string;
  provider: string;
  name: string;
  plan: string;
  state: 'ok' | 'refreshing' | 'warning' | 'stale';
  metrics: Metric[];
};
type Provider = {
  id: string;
  name: string;
  icon: string;
  blurb: string;
  unified: boolean;
  added: boolean;
  accounts: Account[];
};

const MIN = 60_000;
const H = 3_600_000;
const D = 86_400_000;

const pct = (f: number) => `${Math.round(f * 100)}%`;
const usd = (n: number) => `$${n.toFixed(2)}`;
const statusOf = (pctLeft: number): Metric['status'] =>
  pctLeft <= 0 ? 'usedup' : pctLeft <= 0.15 ? 'critical' : pctLeft <= 0.3 ? 'warning' : 'ok';

const limit = (id: string, label: string, pctLeft: number, resetInMs: number, extra: Partial<Metric> = {}): Metric => ({
  id, label, kind: 'limit', pctLeft,
  resets: 0, resetsMax: 0, paceAt: -1,
  amountLeft: pct(pctLeft), amountUsed: pct(1 - pctLeft),
  resetInMs, status: statusOf(pctLeft),
  pinned: false, hidden: false, burningFast: false, ...extra,
});
const money = (id: string, label: string, left: number, total: number, resetInMs: number, extra: Partial<Metric> = {}): Metric => ({
  id, label, kind: 'money', pctLeft: total > 0 ? left / total : 0,
  resets: 0, resetsMax: 0, paceAt: -1,
  amountLeft: usd(left), amountUsed: usd(total - left),
  resetInMs, status: statusOf(total > 0 ? left / total : 0),
  pinned: false, hidden: false, burningFast: false, ...extra,
});
const value = (id: string, label: string, amount: string, detail: string, extra: Partial<Metric> = {}): Metric => ({
  id, label, kind: 'value', pctLeft: -1,
  resets: 0, resetsMax: 0, paceAt: -1,
  amountLeft: amount, amountUsed: detail,
  resetInMs: -1, status: 'plain',
  pinned: false, hidden: false, burningFast: false, ...extra,
});
const resets = (id: string, label: string, left: number, max: number, resetInMs: number, extra: Partial<Metric> = {}): Metric => ({
  id, label, kind: 'resets', pctLeft: max > 0 ? left / max : 0,
  resets: left, resetsMax: max, paceAt: -1,
  amountLeft: `${left} left`, amountUsed: `${max - left} used`,
  resetInMs, status: statusOf(max > 0 ? left / max : 0),
  pinned: false, hidden: false, burningFast: false, ...extra,
});

const catalog = (id: string, name: string, blurb: string): Provider => ({
  id, name, icon: `assets/icons/${id}.svg`, blurb,
  unified: false, added: false, accounts: [],
});

let providers: Provider[] = [
  {
    id: 'claude', name: 'Claude', icon: 'assets/icons/claude.svg',
    blurb: 'Session, weekly and Sonnet limits, overage spend and extra usage.',
    unified: false, added: true,
    accounts: [
      {
        id: 'claude-personal', provider: 'claude', name: 'Personal', plan: 'Max 20x', state: 'ok',
        metrics: [
          limit('claude-personal-session', 'Session', 0.24, H + 49 * MIN, { paceAt: 0.31 }),
          limit('claude-personal-weekly', 'Weekly', 0.58, 2 * D + 4 * H, { paceAt: 0.55, pinned: true }),
          limit('claude-personal-sonnet', 'Sonnet Only', 0.81, 2 * D + 4 * H, { paceAt: 0.55 }),
          money('claude-personal-overage', 'Overage Spend', 161.8, 200, 2 * D + 4 * H),
          resets('claude-personal-extra', 'Extra Usage', 5, 5, 2 * D + 4 * H),
          value('claude-personal-today', 'Today', '2.4M tokens', '2.4M'),
        ],
      },
      {
        id: 'claude-work', provider: 'claude', name: 'Work', plan: 'Pro', state: 'ok',
        metrics: [
          limit('claude-work-session', 'Session', 0.18, 41 * MIN, { paceAt: 0.24 }),
          limit('claude-work-weekly', 'Weekly', 0.67, 2 * D + 4 * H, { paceAt: 0.55 }),
        ],
      },
    ],
  },
  {
    id: 'codex', name: 'ChatGPT', icon: 'assets/icons/codex.svg',
    blurb: 'Session and weekly limits for ChatGPT and Codex sign-ins.',
    unified: false, added: true,
    accounts: [{
      id: 'codex-personal', provider: 'codex', name: 'Personal', plan: 'Pro', state: 'ok',
      metrics: [
        limit('codex-session', 'Session', 0.88, 3 * H, { paceAt: 0.32 }),
        limit('codex-weekly', 'Weekly', 0.67, 4 * D, { paceAt: 0.6 }),
      ],
    }],
  },
  {
    id: 'cursor', name: 'Cursor', icon: 'assets/icons/cursor.svg',
    blurb: 'Plan usage total for a Cursor sign-in.',
    unified: false, added: true,
    accounts: [{
      id: 'cursor-main', provider: 'cursor', name: 'main', plan: 'Pro', state: 'ok',
      metrics: [limit('cursor-total', 'Total', 0.54, 9 * D, { paceAt: 0.62 })],
    }],
  },
  {
    id: 'copilot', name: 'GitHub Copilot', icon: 'assets/icons/copilot.svg',
    blurb: 'Monthly premium-request limit for a GitHub sign-in.',
    unified: false, added: true,
    accounts: [{
      id: 'copilot-user', provider: 'copilot', name: 'user', plan: 'Pro', state: 'ok',
      metrics: [limit('copilot-monthly', 'Monthly', 0.71, 12 * D, { paceAt: 0.5 })],
    }],
  },
  {
    id: 'devin', name: 'Devin', icon: 'assets/icons/devin.svg',
    blurb: 'Credit balance for a Devin workspace.',
    unified: false, added: true,
    accounts: [{
      id: 'devin-team', provider: 'devin', name: 'team', plan: '', state: 'ok',
      metrics: [money('devin-credits', 'Total Credits', 0, 50, 8 * D + 2 * H)],
    }],
  },
  catalog('amp', 'Amp', 'Session and weekly limits for an Amp sign-in.'),
  catalog('antigravity', 'Antigravity', 'Model quotas for an Antigravity sign-in.'),
  catalog('grok', 'Grok', 'Usage windows for a Grok sign-in.'),
  catalog('muse', 'Muse', 'Session and weekly limits for a Muse sign-in.'),
  catalog('ollama', 'Ollama', 'Local Ollama models and their loaded state.'),
  catalog('opencode', 'OpenCode', 'Usage limits for an OpenCode sign-in.'),
  catalog('openrouter', 'OpenRouter', 'Credits and rate limits for an OpenRouter key.'),
  catalog('zai', 'Z.ai', 'Session and weekly limits for a Z.ai sign-in.'),
  catalog('cliproxyapi', 'CLIProxyAPI', 'A hub of accounts proxied through CLIProxyAPI.'),
];

let generatedAt = 0; // set from the view's clock on the first board answer
const REFRESH_MS = 5 * MIN;

const eachMetric = (fn: (m: Metric, a: Account, p: Provider) => void) => {
  for (const p of providers) for (const a of p.accounts) for (const m of a.metrics) fn(m, a, p);
};
const findMetric = (id: string) => {
  for (const p of providers) for (const a of p.accounts) for (const m of a.metrics) if (m.id === id) return m;
  return null;
};
const findAccount = (id: string) => {
  for (const p of providers) for (const a of p.accounts) if (a.id === id) return a;
  return null;
};

function priorityRows(now: number) {
  type Row = { id: string; icon: string; label: string; account: string; tint: string;
    amountLeft: string; amountUsed: string; resetInMs: number; pctLeft: number };
  const pinned: Row[] = [], running: Row[] = [], usedUp: Row[] = [];
  eachMetric((m, a, p) => {
    if (m.hidden || (m.kind !== 'limit' && m.kind !== 'money')) return;
    const row: Row = {
      id: m.id, icon: p.icon, label: m.label, account: a.name,
      tint: m.status === 'usedup' ? 'red' : m.status === 'critical' ? 'red'
        : m.status === 'warning' ? 'orange' : 'blue',
      amountLeft: m.amountLeft, amountUsed: m.amountUsed,
      resetInMs: m.resetInMs, pctLeft: Math.max(0, m.pctLeft),
    };
    if (m.pinned) pinned.push(row);
    else if (m.status === 'usedup') usedUp.push(row);
    else if (m.status === 'warning' || m.status === 'critical') running.push(row);
  });
  const groups = [
    { id: 'Pinned', rows: pinned },
    { id: 'Running Out', rows: running },
    { id: 'Used Up', rows: usedUp },
  ].filter((g) => g.rows.length > 0);
  return groups;
}

function menubarText(): string {
  const visible: Metric[] = [];
  eachMetric((m) => {
    if (!m.hidden && (m.kind === 'limit' || m.kind === 'money')) visible.push(m);
  });
  const pinned = visible.filter((m) => m.pinned);
  const worst = visible.length ? visible.reduce((a, b) => (b.pctLeft < a.pctLeft ? b : a)) : undefined;
  const parts = pinned.map((m) => `${m.label} ${m.amountLeft}`);
  if (worst && parts.length === 0) parts.push(`${worst.label} ${worst.amountLeft}`);
  return parts.slice(0, 2).join(' · ') || 'OpenUsage';
}

const ok = () => ({ ok: true });
const onoff = (v: unknown) => v === true || v === 'true';

const mutations = {
  setPinned: ([id, on]: [string, unknown]) => { const m = findMetric(id); if (m) m.pinned = onoff(on); },
  setHidden: ([id, on]: [string, unknown]) => { const m = findMetric(id); if (m) m.hidden = onoff(on); },
  setUnified: ([providerId, on]: [string, unknown]) => { const p = providers.find((x) => x.id === providerId); if (p) p.unified = onoff(on); },
  refreshProvider: ([providerId]: [string]) => {
    const p = providers.find((x) => x.id === providerId);
    if (p) for (const a of p.accounts) a.state = 'refreshing';
  },
  refreshAll: () => { for (const p of providers) for (const a of p.accounts) a.state = 'refreshing'; },
  refreshDone: () => {
    for (const p of providers) for (const a of p.accounts) if (a.state === 'refreshing') a.state = 'ok';
  },
  addAccount: ([providerId]: [string]) => {
    const p = providers.find((x) => x.id === providerId);
    if (!p) return;
    p.added = true;
    const n = p.accounts.length + 1;
    p.accounts.push({
      id: `${providerId}-a${n}`, provider: providerId,
      name: `Account ${n}`, plan: '', state: 'ok',
      metrics: [
        limit(`${providerId}-a${n}-session`, 'Session', 0.92, 4 * H),
        limit(`${providerId}-a${n}-weekly`, 'Weekly', 0.96, 6 * D),
      ],
    });
  },
  renameAccount: ([id, name]: [string, string]) => { const a = findAccount(id); if (a && name.trim()) a.name = name.trim(); },
  removeAccount: ([id]: [string]) => {
    for (const p of providers) {
      const i = p.accounts.findIndex((a) => a.id === id);
      if (i >= 0) { p.accounts.splice(i, 1); if (p.accounts.length === 0) p.added = false; }
    }
  },
};

const sources: Sources = {
  board: ([nowMs, utcOffset]): Result<'board'> => {
    const now = Number(nowMs) || 0;
    if (!generatedAt) generatedAt = now;
    const left = Math.max(0, generatedAt + REFRESH_MS - now);
    const nextIn = left >= H ? `${Math.round(left / H)}h`
      : left >= MIN ? `${Math.round(left / MIN)}m` : `${Math.max(1, Math.round(left / 1000))}s`;
    return {
      menubar: menubarText(),
      nextIn,
      groups: priorityRows(now),
      providers,
    };
  },
  catalog: (): Result<'catalog'> => ({
    providers: providers.map((p) => ({ id: p.id, name: p.name, icon: p.icon, blurb: p.blurb, added: p.added })),
  }),
  setPinned: (args): Result<'setPinned'> => { mutations.setPinned(args as [string, unknown]); return ok(); },
  setHidden: (args): Result<'setHidden'> => { mutations.setHidden(args as [string, unknown]); return ok(); },
  setUnified: (args): Result<'setUnified'> => { mutations.setUnified(args as [string, unknown]); return ok(); },
  refreshProvider: (args): Result<'refreshProvider'> => { mutations.refreshProvider(args as [string]); return ok(); },
  refreshAll: (): Result<'refreshAll'> => { mutations.refreshAll(); return ok(); },
  refreshDone: (): Result<'refreshDone'> => { mutations.refreshDone(); return ok(); },
  addAccount: (args): Result<'addAccount'> => { mutations.addAccount(args as [string]); return ok(); },
  renameAccount: (args): Result<'renameAccount'> => { mutations.renameAccount(args as [string, string]); return ok(); },
  removeAccount: (args): Result<'removeAccount'> => { mutations.removeAccount(args as [string]); return ok(); },
};

export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args, store, storage, native);
