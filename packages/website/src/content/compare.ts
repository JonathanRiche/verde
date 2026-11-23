//! Content for `/compare` (Verde next to other agent workspaces).
//!
//! One source feeds the HTML page (`routes/compare.tsx`), the raw markdown
//! mirror (`/compare.md`), and `/llms-full.txt`, so the claims cannot drift
//! between them.
//!
//! Every statement about another product must come from a fact checked
//! against that product's own repo, docs, or changelog on the date in
//! `COMPARE_LAST_CHECKED`. Unchecked cells say "Not checked"; do not fill
//! them from memory. Verde-side claims follow the README and desktop sources.
//!
//! Text fields are "rich" strings: `code` spans and [label](href) links only.

import { SITE_ORIGIN } from '../lib/seo'

export const COMPARE_LAST_CHECKED = 'November 23, 2026'
export const COMPARE_ISSUES_URL = 'https://github.com/JonathanRiche/verde/issues/new'
export const COMPARE_TITLE = 'Verde compared with other agent workspaces'
export const COMPARE_DESCRIPTION =
  'An honest comparison of Verde with T3 Code, Conductor, Orca, Paseo, Paradev, Emdash, and herdr: app shell, telemetry, background agents, platforms, license, and the features Verde lacks.'

export const compareProducts = [
  'Verde',
  'T3 Code',
  'Conductor',
  'Orca',
  'Paseo',
  'Paradev',
  'Emdash',
  'herdr',
] as const

export interface CompareRow {
  label: string
  /** One cell per entry in `compareProducts`, in the same order. */
  cells: readonly string[]
}

const NC = 'Not checked'

export const compareRows: readonly CompareRow[] = [
  {
    label: 'App shell',
    cells: [
      'Native (Zig, own GPU UI)',
      'Electron',
      'Electron',
      'Electron',
      'Electron',
      'Electron',
      'Electron',
      'Native desktop app (Rust + GPUI); also a TUI',
    ],
  },
  {
    label: 'Telemetry by default',
    cells: [
      'None',
      'On (opt-out)',
      'On (opt-out)',
      'On (opt-out)',
      'None',
      'On (opt-out)',
      'On (opt-out)',
      'Desktop app: on (opt-out). TUI: none found',
    ],
  },
  {
    label: 'Agents keep running after you quit',
    cells: [
      'Yes, by default',
      'Only when the server runs as a background service (`t3 up`)',
      'Local workspaces: no. Cloud workspaces: yes',
      'Yes (terminal sessions; not across a reboot)',
      'Only with "Keep daemon running after quit" enabled',
      NC,
      NC,
      NC,
    ],
  },
  {
    label: 'Desktop platforms',
    cells: [
      'Linux, macOS, Windows (x64)',
      'macOS, Windows, Linux',
      'macOS only (Windows/Linux waitlist)',
      'macOS, Windows, Linux',
      'macOS, Windows, Linux',
      'macOS, experimental Linux AppImage; no Windows',
      'macOS, Windows, Linux',
      'Linux, macOS, Windows',
    ],
  },
  {
    label: 'Web and phone',
    cells: [
      'Web client; iOS and Android in private beta',
      'Web, iOS, Android',
      'iOS app',
      'iOS and Android companion',
      'Web, iOS, Android',
      'Mobile on the Pro plan',
      NC,
      'Phone app in stores',
    ],
  },
  {
    label: 'License and price',
    cells: [
      'MIT, free',
      'MIT, free',
      'Proprietary; free locally, paid plans for cloud',
      'MIT, free',
      'Apache-2.0, free (hosted Hub has a paid Pro plan)',
      'MIT; free for 1 user, Pro $20/user/month',
      'Apache-2.0, free',
      'Apache-2.0, free',
    ],
  },
  {
    label: 'Git worktree per task',
    cells: ['No', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes'],
  },
  {
    label: 'Open PR, checks, and merge in the app',
    cells: ['Opens the PR on GitHub; no checks or merge', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes', 'Yes', NC],
  },
  {
    label: 'Issue intake (GitHub, Linear, …)',
    cells: ['No', 'Yes', 'Yes', 'Yes', NC, 'Yes (Linear on Pro)', 'Yes', NC],
  },
  {
    label: 'Rewind a turn / checkpoints',
    cells: ['No', 'Yes', 'Yes', NC, 'Yes', NC, NC, NC],
  },
]

/** Details behind the table cells: opt-out switches, renames, caveats. */
export const compareNotes: readonly string[] = [
  'Telemetry opt-outs. T3 Code uses PostHog (`T3CODE_TELEMETRY_ENABLED=false`). Conductor uses PostHog, with an in-app toggle since v0.97.0. Orca uses PostHog (Settings, or `DO_NOT_TRACK=1`). Paradev uses PostHog and Sentry, with an in-app toggle. Emdash uses PostHog (`TELEMETRY_ENABLED=false`). The herdr desktop app sends a daily report (`HERDR_TELEMETRY=0`); we found no telemetry code in the herdr TUI.',
  'Verde has no analytics or crash-reporting service. It writes a local `mcp-events.jsonl` log of MCP call outcomes on your machine and does not send it anywhere. It also looks up the latest Verde release on GitHub and each agent CLI’s public latest-version document; those are version checks, not usage reports. The agent CLIs you run keep their own telemetry settings.',
  'Conductor moved from Tauri to Electron in v0.95.0 (November 16, 2026).',
  'T3 Code: when the desktop app hosts the backend, it stops with the app on Windows and Linux. The T3 Connect relay is free for 3 machines.',
  'Orca’s daemon keeps terminal sessions alive through quit, crash, and update, but not a reboot.',
  'Paradev was called Superset until October 26, 2026. It has been MIT-licensed since November 4, 2026 (Elastic License 2.0 before). The Pro plan gates remote access, automations, Linear and Slack integration, and mobile.',
  'Emdash here means “Emdash Classic”, the open-source desktop app. New development has moved to the cloud-first Emdash 2.0, which this page does not cover.',
  'herdr is a Rust terminal multiplexer (TUI); herdr-app is its native desktop app.',
  'Verde release builds are Linux x86_64, macOS, and Windows x64. Its iOS and Android apps are a private beta and are not in the app stores.',
]

export interface CompareItem {
  title: string
  body: string
}

/** The three differences that hold up against every product on the page. */
export const compareHighlights: readonly CompareItem[] = [
  {
    title: 'Native, not Electron.',
    body: 'Verde is a Zig app on its own GPU UI framework, Palette, and its browser pane uses the system webview instead of a bundled Chromium. T3 Code, Conductor, Orca, Paseo, Paradev, and Emdash are Electron apps. herdr’s desktop app is the other native one here (Rust + GPUI).',
  },
  {
    title: 'No telemetry.',
    body: 'Verde has no analytics or crash reporting. T3 Code, Conductor, Orca, Paradev, Emdash, and the herdr desktop app collect telemetry by default; each lets you turn it off. Paseo has none either.',
  },
  {
    title: 'Agents keep running after you quit.',
    body: 'A headless session daemon owns every chat turn and terminal, so closing Verde does not stop your agents, and that is the default. Conductor’s local sessions end when the app closes, Paseo needs an opt-in setting, and T3 Code needs its server running as a background service. Orca’s daemon also keeps terminal sessions alive through quit.',
  },
]

export const verdeGaps: readonly CompareItem[] = [
  {
    title: 'No worktree per task.',
    body: 'Every other tool on this page can put each task in its own git worktree. Verde’s chats share the project’s checkout. Its Changes panel shows which chat changed which file, but it does not isolate them. You can run `git worktree add` yourself and import that folder as its own project; Verde will not create or clean it up for you.',
  },
  {
    title: 'No checks or merge flow.',
    body: 'Verde can commit a chat’s changes, commit them on a new branch, push, and open the pull request on GitHub through the GitHub CLI (`gh`). It stops there: watching CI and merging happen in a terminal or on your Git host, and other Git hosts are not supported. T3 Code, Conductor, Orca, Paseo, Paradev, and Emdash cover checks and merge inside the app.',
  },
  {
    title: 'No issue intake.',
    body: 'Verde does not pull tasks from GitHub Issues, Linear, or other trackers. Paste the issue into a chat or let the agent fetch it with its own tools.',
  },
  {
    title: 'No turn rewind or checkpoints.',
    body: 'You cannot roll a chat and its file changes back to an earlier turn. Commit often if you want restore points.',
  },
  {
    title: 'No plugins.',
    body: 'Verde has no plugin system. You can script the running app from your shell with `verde live`, give agents control over MCP, and add your own ACP agents in settings.',
  },
  {
    title: 'No phone apps in the stores yet.',
    body: 'The iOS and Android apps are a private beta. The web client works today.',
  },
  {
    title: 'A reboot still stops running turns.',
    body: 'The daemon survives closing the app, restarts, and upgrades, not a reboot of the machine.',
  },
]

export const pickSomethingElse: readonly CompareItem[] = [
  {
    title: 'You want every task isolated in its own worktree automatically.',
    body: 'Any of the other seven tools does this.',
  },
  {
    title: 'You want to watch checks and merge without leaving the app.',
    body: 'Look at T3 Code, Conductor, Orca, Paseo, Paradev, or Emdash.',
  },
  {
    title: 'Your work starts from an issue tracker.',
    body: 'T3 Code, Conductor, Orca, and Emdash take issues in directly; Paradev does too, with Linear on its Pro plan.',
  },
  {
    title: 'You rely on rewinding an agent to an earlier turn.',
    body: 'T3 Code, Conductor, and Paseo have checkpoints.',
  },
  {
    title: 'You need a phone app from the app stores today.',
    body: 'T3 Code, Orca, Paseo, and herdr have one; Conductor on iOS; Paradev on its Pro plan.',
  },
  {
    title: 'You want agents running on hosted machines while your laptop is off.',
    body: 'Conductor’s cloud workspaces (paid plans) keep going after you close the app. Verde only connects to machines you run yourself.',
  },
  {
    title: 'You want a terminal multiplexer, not a GUI.',
    body: 'herdr’s TUI is a Rust terminal multiplexer, Apache-2.0, and we found no telemetry code in it.',
  },
]

/** Markdown version of the page, for `/compare.md` and `/llms-full.txt`. */
export function renderCompareMarkdown(): string {
  const lines: string[] = [
    `# ${COMPARE_TITLE}`,
    '',
    `Source: ${SITE_ORIGIN}/compare`,
    `Last checked: ${COMPARE_LAST_CHECKED}. Competitor facts come from each tool's own repo, docs, or changelog on that date. These products change fast; report a mistake at ${COMPARE_ISSUES_URL}.`,
    '',
    '## Where Verde is different',
    '',
  ]
  for (const item of compareHighlights) lines.push(`- **${item.title}** ${item.body}`)
  lines.push('', '## At a glance', '')
  lines.push(`| | ${compareProducts.join(' | ')} |`)
  lines.push(`| --- | ${compareProducts.map(() => '---').join(' | ')} |`)
  for (const row of compareRows) lines.push(`| ${row.label} | ${row.cells.join(' | ')} |`)
  lines.push('', '### Notes', '')
  for (const note of compareNotes) lines.push(`- ${note}`)
  lines.push('', '## Where Verde is behind', '')
  for (const item of verdeGaps) lines.push(`- **${item.title}** ${item.body}`)
  lines.push('', '## When to pick something else', '')
  for (const item of pickSomethingElse) lines.push(`- **${item.title}** ${item.body}`)
  lines.push(
    '',
    `Moving from Conductor? See [Coming from Conductor](${SITE_ORIGIN}/docs/coming-from-conductor).`,
    '',
  )
  return lines.join('\n')
}
