import { For, Show } from 'solid-js'
import type { UsageSummary } from '../lib/usage'

export function UsageCard(props: { usage: UsageSummary }) {
  return <article class="usage-card" aria-label={`${props.usage.provider} usage`}>
    <div class="composer-surface-heading"><strong>{props.usage.provider === 'codex' ? 'Codex' : 'Claude'} usage</strong><span>Reported usage</span></div>
    <For each={props.usage.limits}>{limit => <div class="usage-limit">
      <div><span>{limit.label}</span><strong>{limit.percent_left}% left</strong></div>
      <meter min="0" max="100" value={limit.percent_left} aria-label={`${limit.label}: percentage left`} />
      <Show when={limit.reset}><p class="composer-detail">{limit.reset}</p></Show>
    </div>}</For>
    <Show when={props.usage.stats.length}><dl class="usage-stats"><For each={props.usage.stats}>{stat => <div><dt>{stat.label}</dt><dd>{stat.value}</dd></div>}</For></dl></Show>
    <Show when={props.usage.recent.length}><details><summary>Recent daily usage</summary><dl class="usage-stats"><For each={props.usage.recent}>{stat => <div><dt>{stat.label}</dt><dd>{stat.value}</dd></div>}</For></dl></details></Show>
  </article>
}
