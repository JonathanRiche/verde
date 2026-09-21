import { expect, test } from 'bun:test'
import { emphasisSpans, tokenize } from './highlight'

const comments = (text, lang) => tokenize(text, lang).filter((t) => t.cls === 'tok-comment').map((t) => t.text)
const lossless = (text, lang) => expect(tokenize(text, lang).map((t) => t.text).join('')).toBe(text)

test('tokenizer is lossless', () => {
  for (const [text, lang] of [
    ['const a = "// not" // yes\n', 'ts'], ['rm build/*\nls */\n', 'sh'], ['x = `a ${`b`} c`', 'js'],
    ["fn f<'a>(x: &'a str) {}", 'rust'], ['', 'ts'], ['x'.repeat(20_001), 'ts'],
  ]) lossless(text, lang)
})

test('shell globs and expansions are not comments', () => {
  expect(comments('rm build/*\necho hi\nls */\n', 'sh')).toEqual([])
  expect(comments('echo ${#arr} $# ${v#pre} # real', 'bash')).toEqual(['# real'])
})

test('comment markers inside strings stay strings', () => {
  expect(comments('const a = "// no /* no */" // yes', 'ts')).toEqual(['// yes'])
  expect(comments('x = "# no"  # yes', 'py')).toEqual(['# yes'])
})

test('urls are not slash comments', () => {
  expect(comments('fetch(https://example.com/a)', 'go')).toEqual([])
  expect(comments('GET http://x // y', 'console')).toEqual([])
})

test('block comments stay on for c-family, css and sql', () => {
  expect(comments('a /* b */ c', 'c')).toEqual(['/* b */'])
  expect(comments('a { } /* b */', 'css')).toEqual(['/* b */'])
  expect(comments('select 1 /* b */ -- c', 'sql')).toEqual(['/* b */', '-- c'])
})

test('emphasis marks the changed middle', () => {
  expect(emphasisSpans('const a = 1;', 'const a = 2;')).toEqual({ a: [10, 11], b: [10, 11] })
})

test('emphasis skips unrelated lines sharing indentation', () => {
  expect(emphasisSpans('    return foo(bar)', '    while (x) {')).toBeNull()
  expect(emphasisSpans('abc', 'xyz')).toBeNull()
})

test('emphasis never splits a surrogate pair', () => {
  const spans = emphasisSpans('say "hello" 😀 there friend', 'say "hello" 😁 there friend')
  expect(spans.a).toEqual([12, 14])
})

test('YAML globs and URL fragments do not swallow later lines as comments', () => {
  const text = 'paths: build/*\nurl: https://example.com/a//b#fragment\nnext: true # note\n'
  expect(comments(text, 'yaml')).toEqual(['# note'])
  expect(comments('curl https://example.com/a//b#fragment # real', 'bash')).toEqual(['# real'])
  expect(comments('fetch(https://example.com/a//b) // real', 'go')).toEqual(['// real'])
  lossless(text, 'yaml')
})

import { JSDOM } from 'jsdom'
import { copyText, decorateCodeBlocks, highlightedFragment } from './highlight'

test('fragments preserve exact text and independent nodes even after cache reuse', () => {
  const document = new JSDOM('').window.document
  const source = 'const x = "<script>alert(1)</script>";\n😀\t  '
  const first = highlightedFragment(document, source, 'ts')
  const second = highlightedFragment(document, source, 'ts')
  expect(first.textContent).toBe(source)
  expect(second.textContent).toBe(source)
  first.firstChild.textContent = 'changed'
  expect(second.textContent).toBe(source)
  expect(second.querySelector('script')).toBeNull()
  for (let index = 0; index < 80; index++) highlightedFragment(document, `${index} ${'x'.repeat(4000)}`, 'ts')
  expect(highlightedFragment(document, source, 'ts').textContent).toBe(source)
  expect(highlightedFragment(document, source, 'text').querySelector('.tok-comment')).toBeNull()
})

test('a streaming wrapper gains highlighting without another toolbar; copy excludes controls', async () => {
  const document = new JSDOM('<div id="root"><pre><code class="language-ts"></code></pre></div>').window.document
  const root = document.querySelector('#root')
  const source = 'const x = "hello";\n\t😀  '
  root.querySelector('code').textContent = source
  let copied = null
  Object.defineProperty(document.defaultView.navigator, 'clipboard', { value: { writeText: async (value) => { copied = value } } })
  decorateCodeBlocks(root, false)
  expect(root.querySelector('.tok-keyword')).toBeNull()
  decorateCodeBlocks(root, true)
  expect(root.querySelector('.tok-keyword').textContent).toBe('const')
  expect(root.querySelectorAll('.code-toolbar').length).toBe(1)
  expect(root.querySelector('pre').textContent).toBe(source)
  root.querySelector('button').click()
  await new Promise((resolve) => setTimeout(resolve, 0))
  expect(copied).toBe(source)
  expect(root.querySelector('[role="status"]').textContent).toBe('Copied')
})

test('clipboard failures remain visible and are announced', async () => {
  await expect(copyText('x', { writeText: async () => { throw new Error('denied') } })).rejects.toThrow('denied')
  const document = new JSDOM('<div id="root"><pre><code>x</code></pre></div>').window.document
  const root = document.querySelector('#root')
  Object.defineProperty(document.defaultView.navigator, 'clipboard', { value: { writeText: async () => { throw new Error('denied') } } })
  decorateCodeBlocks(root, true)
  root.querySelector('button').click()
  await new Promise((resolve) => setTimeout(resolve, 0))
  expect(root.querySelector('[aria-live="polite"]').textContent).toContain('Copy failed')
})
