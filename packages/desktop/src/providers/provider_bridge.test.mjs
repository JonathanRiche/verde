import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

// Exercise the bridge with an in-memory SDK, without stdin or a live provider.
const source = readFileSync(new URL('./provider_bridge.ts', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '')
  .replace(/main\(\)\.catch\([\s\S]*$/, '');
function bridge() {
  const events = [];
  const context = vm.createContext({ process: { env: {}, stdout: { write: line => events.push(JSON.parse(line)) } } });
  vm.runInContext(source, context);
  return { context, events };
}
const tool = (name, input, id = 'agent') => ({ type: 'assistant', message: { content: [{ type: 'tool_use', name, input, id }] } });
const result = (is_error = false) => ({ type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 'agent', content: 'agent launch result', is_error }] } });
const turn = { type: 'result', result: 'reply' };

for (const status of ['completed', 'failed', 'stopped']) {
  test(`background agent stays alive until ${status} notification and final reply`, { timeout: 2000 }, async () => {
    const { context, events } = bridge();
    const sdk = { async *query({ prompt }) {
      const input = prompt[Symbol.asyncIterator]();
      await input.next();
      let closed = false;
      const end = input.next().then(value => { closed = value.done; });
      yield tool('Agent', { description: 'Build previews', run_in_background: true });
      yield { type: 'system', subtype: 'task_started', task_id: 'task', tool_use_id: 'agent' };
      yield result();
      yield turn;
      await new Promise(setImmediate);
      assert.equal(closed, false, 'initial reply must not close SDK input');
      assert.equal(events.filter(e => e.kind === 'subagent' && e.status !== 'in_progress').length, 0);
      // Some SDK notifications omit tool_use_id.
      yield { type: 'system', subtype: 'task_notification', task_id: 'task', status, summary: 'Agent finished' };
      yield turn;
      await end;
      assert.equal(closed, true);
    } };
    await context.handleClaudeSendPrompt(sdk, { prompt: 'test' });
    assert.equal(events.find(e => e.kind === 'subagent' && e.status !== 'in_progress').status, status === 'completed' ? 'completed' : 'failed');
  });
}

for (const background of [false, true]) {
  test(`agent launch failure closes input (background=${background})`, { timeout: 2000 }, async () => {
    const { context } = bridge();
    await context.handleClaudeSendPrompt({ async *query({ prompt }) {
      const input = prompt[Symbol.asyncIterator]();
      await input.next();
      yield tool('Agent', { run_in_background: background });
      yield result(true);
      yield turn;
      assert.equal((await input.next()).done, true);
    } }, { prompt: 'test' });
  });
}

test('SDK background membership keeps automatically backgrounded work alive', { timeout: 2000 }, async () => {
  const { context } = bridge();
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    let closed = false;
    const end = input.next().then(value => { closed = value.done; });
    yield { type: 'system', subtype: 'background_tasks_changed', tasks: [{ task_id: 'auto' }] };
    yield turn;
    await new Promise(setImmediate);
    assert.equal(closed, false);
    yield { type: 'system', subtype: 'background_tasks_changed', tasks: [] };
    yield turn;
    await end;
    assert.equal(closed, true);
  } }, { prompt: 'test' });
});

test('failed command preserves tool error text', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  await context.handleClaudeSendPrompt({ async *query() {
    yield tool('Bash', { command: 'cat instructions.md' });
    yield result(true);
    yield turn;
  } }, { prompt: 'test' });
  assert.equal(events.find(e => e.title === 'Command failed').body, 'cat instructions.md\n\nagent launch result');
});

test('one finished agent does not close input while another is running', { timeout: 2000 }, async () => {
  const { context } = bridge();
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    let closed = false;
    const end = input.next().then(value => { closed = value.done; });
    yield tool('Agent', { run_in_background: true }, 'first');
    yield tool('Task', { run_in_background: true }, 'second');
    yield turn;
    yield { type: 'system', subtype: 'task_notification', tool_use_id: 'first', status: 'completed' };
    yield turn;
    await new Promise(setImmediate);
    assert.equal(closed, false);
    yield { type: 'system', subtype: 'task_notification', tool_use_id: 'second', status: 'completed' };
    yield turn;
    await end;
    assert.equal(closed, true);
  } }, { prompt: 'test' });
});

test('foreground agent completes normally', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield tool('Agent', {});
    yield result();
    yield turn;
    assert.equal((await input.next()).done, true);
  } }, { prompt: 'test' });
  assert.equal(events.filter(e => e.kind === 'subagent' && e.status === 'completed').length, 1);
});

test('child agent messages stream as transcript chunks on the parent call', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  const child = (content, type = 'assistant') => ({ type, parent_tool_use_id: 'agent', message: { content } });
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield tool('Agent', { description: 'Explore repo' });
    yield child([{ type: 'text', text: 'Looking around.' }, { type: 'tool_use', id: 'c1', name: 'Bash', input: { command: 'ls' } }]);
    yield child([{ type: 'tool_result', tool_use_id: 'c1', content: 'README.md' }], 'user');
    yield child([{ type: 'tool_use', id: 'c2', name: 'Read', input: { file_path: '/repo/README.md' } }]);
    yield result();
    yield turn;
  } }, { prompt: 'test' });
  const chunks = events.filter(e => e.type === 'tool_call_event' && e.transcript);
  assert.equal(chunks.length, 3);
  assert.ok(chunks.every(e => e.call_id === 'agent' && e.kind === 'subagent' && e.status === undefined));
  const entries = chunks.flatMap(e => e.transcript.trimEnd().split('\n').map(line => JSON.parse(line)));
  assert.deepEqual(entries.map(e => e.type), ['text', 'tool_use', 'tool_result', 'tool_use']);
  assert.equal(entries[1].kind, 'execute');
  assert.equal(entries[1].input, 'ls');
  assert.equal(entries[3].title, 'Read /repo/README.md');
  assert.equal(entries[3].kind, 'read');
  // Child activity stays out of the parent transcript and reply.
  assert.equal(events.filter(e => e.type === 'stream_event').length, 0);
  assert.equal(events.filter(e => e.type === 'delta').length, 0);
  assert.equal(events.find(e => e.type === 'result').reply_text, 'reply');
});

test('child text streams as ephemeral deltas before the block lands', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  const delta = text => ({ type: 'stream_event', parent_tool_use_id: 'agent', event: { type: 'content_block_delta', delta: { type: 'text_delta', text } } });
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield tool('Agent', { description: 'Explore repo' });
    yield delta('Look');
    yield delta('ing around.');
    yield { type: 'assistant', parent_tool_use_id: 'agent', message: { content: [{ type: 'thinking', thinking: 'Where to start?' }, { type: 'text', text: 'Looking around.' }] } };
    yield result();
    yield turn;
  } }, { prompt: 'test' });
  const partials = events.filter(e => e.transcript_delta !== undefined);
  assert.deepEqual(partials.map(e => e.transcript_delta), ['Look', 'ing around.']);
  assert.ok(partials.every(e => e.call_id === 'agent' && e.kind === 'subagent' && e.transcript === undefined && e.status === undefined));
  const entries = events.filter(e => e.transcript).flatMap(e => e.transcript.trimEnd().split('\n').map(line => JSON.parse(line)));
  assert.deepEqual(entries, [{ type: 'thinking', text: 'Where to start?' }, { type: 'text', text: 'Looking around.' }]);
  // Child streaming never reaches the parent transcript or its reply.
  assert.equal(events.filter(e => e.type === 'delta').length, 0);
  assert.equal(events.find(e => e.type === 'result').reply_text, 'reply');
});

test('background child agents stream on the parent call and still complete', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    let closed = false;
    const end = input.next().then(value => { closed = value.done; });
    yield tool('Agent', { description: 'Watch builds', run_in_background: true });
    yield { type: 'system', subtype: 'task_started', task_id: 'task', tool_use_id: 'agent' };
    yield result();
    yield turn;
    yield { type: 'stream_event', parent_tool_use_id: 'agent', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Watch' } } };
    yield { type: 'assistant', parent_tool_use_id: 'agent', message: { content: [{ type: 'text', text: 'Watching.' }] } };
    await new Promise(setImmediate);
    assert.equal(closed, false, 'a streaming background child must keep SDK input open');
    yield { type: 'system', subtype: 'task_notification', task_id: 'task', status: 'completed', summary: 'Watched' };
    yield turn;
    await end;
    assert.equal(closed, true);
  } }, { prompt: 'test' });
  const childEvents = events.filter(e => e.type === 'tool_call_event' && (e.transcript || e.transcript_delta));
  assert.deepEqual(childEvents.map(e => e.call_id), ['agent', 'agent']);
  assert.equal(childEvents[0].transcript_delta, 'Watch');
  assert.equal(JSON.parse(childEvents[1].transcript.trimEnd()).text, 'Watching.');
  const completion = events.find(e => e.kind === 'subagent' && e.status === 'completed');
  assert.equal(completion.call_id, 'agent');
  assert.equal(completion.output, 'Watched');
});

test('nested child agents stay on the top-level call and carry their parent', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  const child = (content, type = 'assistant') => ({ type, parent_tool_use_id: 'agent', message: { content } });
  const grandchild = (content, type = 'assistant') => ({ type, parent_tool_use_id: 'nested', message: { content } });
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield tool('Task', { description: 'Explore repo', prompt: 'Explore' });
    yield child([
      { type: 'text', text: 'Delegating.' },
      { type: 'tool_use', id: 'nested', name: 'Task', input: { description: 'Read README', prompt: 'Read README.md' } },
    ]);
    yield { type: 'stream_event', parent_tool_use_id: 'nested', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'REA' } } };
    yield grandchild([
      { type: 'thinking', thinking: 'Open the file.' },
      { type: 'tool_use', id: 'g1', name: 'Read', input: { file_path: '/repo/README.md' } },
    ]);
    yield grandchild([{ type: 'tool_result', tool_use_id: 'g1', content: 'hi' }], 'user');
    yield grandchild([{ type: 'text', text: 'README says hi.' }]);
    yield child([{ type: 'tool_result', tool_use_id: 'nested', content: 'nested report' }], 'user');
    yield result();
    yield turn;
  } }, { prompt: 'test' });
  const chunks = events.filter(e => e.type === 'tool_call_event' && e.transcript);
  // No stray card: the grandchild's own tool_use id is never a call id.
  assert.ok(chunks.every(e => e.call_id === 'agent' && e.kind === 'subagent'));
  assert.equal(events.filter(e => e.transcript_delta !== undefined).length, 0);
  const entries = chunks.flatMap(e => e.transcript.trimEnd().split('\n').map(line => JSON.parse(line)));
  assert.deepEqual(entries.map(e => [e.type, e.parent]), [
    ['text', undefined],
    ['tool_use', undefined],
    ['thinking', 'nested'],
    ['tool_use', 'nested'],
    ['tool_result', 'nested'],
    ['text', 'nested'],
    ['tool_result', undefined],
  ]);
  assert.equal(entries[1].kind, 'subagent');
  assert.equal(entries[1].title, 'Read README');
  assert.equal(entries[1].id, 'nested');
  assert.equal(entries[6].id, 'nested');
  assert.equal(entries[6].output, 'nested report');
});
