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

for (const launch of ['structured', 'text']) {
  test(`default-backgrounded agent keeps input open and accepts steering (${launch} launch result)`, { timeout: 2000 }, async () => {
    const { context, events } = bridge();
    await context.handleClaudeSendPrompt({ async *query({ prompt }) {
      const input = prompt[Symbol.asyncIterator]();
      await input.next();
      // Claude Code backgrounds agents without an explicit run_in_background.
      yield tool('Agent', { description: 'Zero-copy frames' });
      yield {
        type: 'user',
        message: { content: [{ type: 'tool_result', tool_use_id: 'agent', content: launch === 'text' ? 'Async agent launched successfully.\nagentId: a1' : 'ok' }] },
        ...(launch === 'structured' ? { tool_use_result: { status: 'async_launched', agentId: 'a1' } } : {}),
      };
      yield turn;
      await new Promise(setImmediate);
      assert.equal(events.filter(e => e.kind === 'subagent' && e.status !== 'in_progress').length, 0, 'launch ack is not completion');
      context.handleInputLine(JSON.stringify({ type: 'steer_prompt', request_id: 7, prompt: 'still going?' }));
      assert.equal(events.find(e => e.type === 'steer_response')?.accepted, true);
      await input.next();
      yield { type: 'system', subtype: 'task_notification', tool_use_id: 'agent', status: 'completed', summary: 'done' };
      yield turn;
      assert.equal((await input.next()).done, true);
    } }, { prompt: 'test' });
    assert.equal(events.find(e => e.kind === 'subagent' && e.status !== 'in_progress').status, 'completed');
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

test('workspace roots reach Claude on resumed turns without widening permission mode', () => {
  const { context } = bridge();
  const options = context.buildClaudeOptions({
    cwd: '/work/app', thread_id: 'existing',
    workspace_roots: ['/work/app', '/work/api with spaces'],
    approval_policy: 'on_request', sandbox_mode: 'workspace_write',
  });
  assert.deepEqual(Array.from(options.additionalDirectories), ['/work/app', '/work/api with spaces']);
  assert.equal(options.resume, 'existing');
  assert.equal(options.permissionMode, 'default');
  assert.equal(options.allowDangerouslySkipPermissions, undefined);
});

const signInRequired = 'Claude Code is not signed in. Sign in, then send your message again.';
test('signed-out Claude reports sign-in instead of the synthetic stop reason', { timeout: 2000 }, async () => {
  const { context } = bridge();
  const signedOut = { type: 'result', subtype: 'success', is_error: true, result: 'Not logged in · Please run /login', stop_reason: 'stop_sequence' };
  await assert.rejects(
    context.handleClaudeSendPrompt({ async *query() { yield signedOut; } }, { prompt: 'test' }),
    { message: signInRequired },
  );
  await assert.rejects(
    context.handleClaudeSendPrompt({ async *query() {
      yield { type: 'assistant', error: 'authentication_failed', message: { content: [{ type: 'text', text: 'Not logged in · Please run /login' }] } };
      yield signedOut;
    } }, { prompt: 'test' }),
    { message: signInRequired },
  );
});

for (const ending of ['notification', 'membership']) {
  test(`agent resumed from an earlier turn gets a live card that finishes (${ending})`, { timeout: 2000 }, async () => {
    const { context, events } = bridge();
    await context.handleClaudeSendPrompt({ async *query({ prompt }) {
      const input = prompt[Symbol.asyncIterator]();
      await input.next();
      yield { type: 'system', subtype: 'background_tasks_changed', tasks: [{ task_id: 'task', task_type: 'local_agent', description: 'Zero-copy frames' }] };
      // No Agent tool_use in this turn: the child streams under its original call.
      yield { type: 'assistant', parent_tool_use_id: 'old-agent', message: { content: [{ type: 'text', text: 'Back at it.' }] } };
      yield { type: 'assistant', parent_tool_use_id: 'old-agent', message: { content: [{ type: 'text', text: 'Still going.' }] } };
      yield turn;
      await new Promise(setImmediate);
      const opened = events.filter(e => e.call_id === 'old-agent' && e.status === 'in_progress');
      assert.equal(opened.length, 1, 'one live card for the resumed agent');
      assert.ok(events.indexOf(opened[0]) < events.findIndex(e => e.call_id === 'old-agent' && e.transcript));
      assert.equal(events.filter(e => e.call_id === 'old-agent' && e.status === 'completed').length, 0);
      if (ending === 'notification') {
        yield { type: 'system', subtype: 'task_notification', task_id: 'task', tool_use_id: 'old-agent', status: 'completed', summary: 'done' };
      }
      yield { type: 'system', subtype: 'background_tasks_changed', tasks: [] };
      yield turn;
      assert.equal((await input.next()).done, true);
    } }, { prompt: 'test' });
    const finished = events.filter(e => e.call_id === 'old-agent' && e.status === 'completed');
    assert.equal(finished.length, 1);
  });
}
