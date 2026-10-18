import { expect, test } from 'bun:test'
import { emphasisSpans, tokenize } from './highlight'

const lossless = (text, lang) => expect(tokenize(text, lang).map((t) => t.text).join('')).toBe(text)

test('tokenizer is lossless', () => {
  for (const [text, lang] of [
    ['const a = "// not" // yes\n', 'ts'], ['rm build/*\nls */\n', 'sh'], ['x = `a ${`b`} c`', 'js'],
    ["fn f<'a>(x: &'a str) {}", 'rust'], ['', 'ts'], ['x'.repeat(20_001), 'ts'],
  ]) lossless(text, lang)
})

test('emphasis never splits a surrogate pair', () => {
  const spans = emphasisSpans('say "hello" 😀 there friend', 'say "hello" 😁 there friend')
  expect(spans.a).toEqual([12, 14])
})
