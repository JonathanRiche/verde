//! First-prompt chat title fallback shared by the web send path and tests.

/// Mirror desktop chat_threads.makeThreadTitle for the first accepted prompt.
/// This durable fallback remains when automatic titles are disabled or the
/// configured title provider fails.
export function makeThreadTitle(prompt: string): string {
  const trimmed = prompt.replace(/^[\t\n\v\f\r ]+|[\t\n\v\f\r ]+$/g, '')
  if (!trimmed) return 'New chat'
  const compact = trimmed.replace(/[\t\n\v\f\r ]+/g, ' ')
  const encoder = new TextEncoder()
  let title = ''
  for (const char of compact) {
    if (encoder.encode(title + char).length > 96) break
    title += char
  }
  return title.trimEnd() || 'New chat'
}
