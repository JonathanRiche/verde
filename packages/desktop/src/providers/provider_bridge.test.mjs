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
