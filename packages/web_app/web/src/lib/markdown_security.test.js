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
