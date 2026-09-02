import { afterAll, describe, expect, test } from 'bun:test'
import createDOMPurify from 'dompurify'
import { JSDOM } from 'jsdom'

import { renderMarkdownWith } from './markdown.ts'

const dom = new JSDOM('', { url: 'https://verde.example/' })
const sanitizer = createDOMPurify(dom.window)

afterAll(() => dom.window.close())

describe('sanitized Markdown', () => {
  test('removes raw scripts and HTML event handlers', () => {
    const html = renderMarkdownWith(
      sanitizer,
      '<script>globalThis.pwned = true</script>\n' +
        '<img src="/safe.png" onerror="globalThis.pwned = true">\n' +
        '<svg onload="globalThis.pwned = true"><circle /></svg>',
    )

    expect(html).not.toContain('<script')
    expect(html).not.toContain('onerror')
    expect(html).not.toContain('<svg')
    expect(html).not.toContain('onload')
    expect(html).toContain('<img src="/safe.png">')
  })

  test('removes javascript URLs from raw HTML and Markdown links', () => {
    const html = renderMarkdownWith(
      sanitizer,
      '<a href="javascript:alert(1)">raw</a> [markdown](javascript:alert(2))',
    )

    expect(html.toLowerCase()).not.toContain('javascript:')
    expect(html).toContain('<a>raw</a>')
  })

  test('keeps a file citation inert while remote file access is unavailable', () => {
    const html = renderMarkdownWith(
      sanitizer,
      ':codex-file-citation{path="/tmp/report one.md" purpose="output"}',
      { fileCitations: true },
    )
    const document = new JSDOM(html).window.document
    const citation = document.querySelector('span.file-citation')

    expect(citation).not.toBeNull()
    expect(citation?.getAttribute('title')).toBe('/tmp/report one.md')
    expect(citation?.getAttribute('href')).toBeNull()
    expect(citation?.getAttribute('data-verde-file')).toBeNull()
    expect(citation?.textContent).toBe('report one.md')
    expect(citation?.querySelector('svg')).toBeNull()
  })

  test('sanitizes repository Markdown through the same boundary', () => {
    const html = renderMarkdownWith(
      sanitizer,
      '# README\n\n<img src=x onerror=alert(1)>\n\n**safe**',
    )

    expect(html).toContain('<h1>README</h1>')
    expect(html).toContain('<strong>safe</strong>')
    expect(html).not.toContain('onerror')
  })

  test('fails closed as inert text when DOM sanitization is unsupported', () => {
    const unsupported = {
      isSupported: false,
      sanitize: () => { throw new Error('must not sanitize with an unsupported DOM') },
    }
    const html = renderMarkdownWith(unsupported, '<img src=x onerror=alert(1)>')

    expect(html).toBe('&#60;img src=x onerror=alert(1)&#62;')
    expect(new JSDOM(html).window.document.querySelector('img')).toBeNull()
  })
})
