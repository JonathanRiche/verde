import { createFileRoute } from '@tanstack/solid-router'
import { For, type JSX } from 'solid-js'

import {
  COMPARE_DESCRIPTION,
  COMPARE_ISSUES_URL,
  COMPARE_LAST_CHECKED,
  COMPARE_TITLE,
  compareHighlights,
  compareNotes,
  compareProducts,
  compareRows,
  pickSomethingElse,
  verdeGaps,
  type CompareItem,
} from '../content/compare'
import { SITE_ORIGIN } from '../lib/seo'

const title = 'Verde vs T3 Code, Conductor, Orca, Paseo, Paradev, Emdash & herdr'
const url = `${SITE_ORIGIN}/compare`

export const Route = createFileRoute('/compare')({
  head: () => ({
    meta: [
      { title },
      { name: 'description', content: COMPARE_DESCRIPTION },
      { property: 'og:type', content: 'website' },
      { property: 'og:url', content: url },
      { property: 'og:title', content: title },
      { property: 'og:description', content: COMPARE_DESCRIPTION },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: title },
      { name: 'twitter:description', content: COMPARE_DESCRIPTION },
    ],
    links: [
      { rel: 'canonical', href: url },
      { rel: 'alternate', type: 'text/markdown', href: `${url}.md` },
    ],
  }),
  component: Compare,
})

/** Render the `code` spans and [label](href) links allowed in compare text. */
function Rich(props: { text: string }): JSX.Element {
  const parts = props.text.split(/(`[^`]+`|\[[^\]]+\]\([^)]+\))/g)
  return (
    <For each={parts}>
      {(part) => {
        if (part.startsWith('`') && part.endsWith('`') && part.length > 1) {
          return <code>{part.slice(1, -1)}</code>
        }
        const link = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(part)
        if (link) {
          const external = link[2]!.startsWith('http')
          return (
            <a
              href={link[2]}
              class="compare-link"
              target={external ? '_blank' : undefined}
              rel={external ? 'noreferrer' : undefined}
            >
              {link[1]}
            </a>
          )
        }
        return part
      }}
    </For>
  )
}

function ItemList(props: { items: readonly CompareItem[] }) {
  return (
    <ul class="compare-list">
      <For each={props.items}>
        {(item) => (
          <li>
            <strong>{item.title}</strong> <Rich text={item.body} />
          </li>
        )}
      </For>
    </ul>
  )
}

function Compare() {
  const structuredData = {
    '@context': 'https://schema.org',
    '@type': 'WebPage',
    '@id': `${url}#page`,
    url,
    name: title,
    description: COMPARE_DESCRIPTION,
    inLanguage: 'en',
    isPartOf: { '@id': `${SITE_ORIGIN}/#website` },
    about: { '@id': `${SITE_ORIGIN}/#software` },
  }

  return (
    <main class="wrap compare-page">
      <script
        type="application/ld+json"
        innerHTML={JSON.stringify(structuredData)}
      />

      <header class="compare-head">
        <p class="tag tag-static">Compare</p>
        <h1 class="heading">{COMPARE_TITLE}.</h1>
        <p class="band-body">
          People trying agent workspaces keep asking how Verde stacks up against
          T3 Code, Conductor, Orca, Paseo, Paradev (formerly Superset), Emdash,
          and herdr. Here is what each one does on the points we could check
          against its own repo, docs, or changelog, including where Verde is
          behind. Where we did not check something, the table says so.
        </p>
        <p class="compare-checked">
          <strong>Last checked: {COMPARE_LAST_CHECKED}.</strong> These products
          change fast. If something here is wrong or out of date,{' '}
          <a href={COMPARE_ISSUES_URL} target="_blank" rel="noreferrer" class="compare-link">
            open a GitHub issue
          </a>{' '}
          and we will fix it.
        </p>
      </header>

      <section class="compare-section" aria-labelledby="compare-different">
        <h2 id="compare-different" class="compare-h2">Where Verde is different</h2>
        <div class="feature-grid">
          <For each={compareHighlights}>
            {(item) => (
              <article class="feature-card">
                <h3>{item.title}</h3>
                <p><Rich text={item.body} /></p>
              </article>
            )}
          </For>
        </div>
      </section>

      <section class="compare-section" aria-labelledby="compare-glance">
        <h2 id="compare-glance" class="compare-h2">At a glance</h2>
        <div
          class="comp-scroll compare-scroll"
          role="region"
          aria-labelledby="compare-caption"
          tabindex="0"
        >
          <table class="comp-table compare-table">
            <caption id="compare-caption" class="compare-caption">
              Verde and seven other agent workspaces, as checked on{' '}
              {COMPARE_LAST_CHECKED}. Scroll sideways to see every column.
            </caption>
            <thead>
              <tr>
                <td class="comp-rowhead" />
                <For each={compareProducts}>
                  {(product, i) => (
                    <th
                      scope="col"
                      class={i() === 0 ? 'comp-col comp-col--verde' : 'comp-col'}
                    >
                      {product}
                    </th>
                  )}
                </For>
              </tr>
            </thead>
            <tbody>
              <For each={compareRows}>
                {(row) => (
                  <tr>
                    <th class="comp-rowhead" scope="row">{row.label}</th>
                    <For each={row.cells}>
                      {(cell, i) => (
                        <td
                          class={`${i() === 0 ? 'comp-td comp-td--verde' : 'comp-td'}${
                            cell === 'Not checked' ? ' compare-unchecked' : ''
                          }`}
                        >
                          <Rich text={cell} />
                        </td>
                      )}
                    </For>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>

        <h3 class="compare-h3">Notes</h3>
        <ul class="compare-list compare-notes">
          <For each={compareNotes}>
            {(note) => (
              <li>
                <Rich text={note} />
              </li>
            )}
          </For>
        </ul>
      </section>

      <section class="compare-section" aria-labelledby="compare-behind">
        <h2 id="compare-behind" class="compare-h2">Where Verde is behind</h2>
        <ItemList items={verdeGaps} />
      </section>

      <section class="compare-section" aria-labelledby="compare-else">
        <h2 id="compare-else" class="compare-h2">When to pick something else</h2>
        <ItemList items={pickSomethingElse} />
      </section>

      <section class="compare-section compare-foot">
        <p class="band-body">
          Moving over from Conductor, or need the same tool on Linux and
          Windows? Read{' '}
          <a href="/docs/coming-from-conductor" class="compare-link">
            Coming from Conductor
          </a>
          . Product names belong to their owners; this page is not affiliated
          with or endorsed by any of them.
        </p>
        <p style={{ 'margin-top': '1.5rem' }}>
          <a href="/docs/quickstart" class="btn btn-primary">
            Read the quickstart
          </a>{' '}
          <a href="/compare.md" class="btn btn-ghost">
            This page as markdown
          </a>
        </p>
      </section>
    </main>
  )
}
