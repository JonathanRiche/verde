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

const state = value => ({ type: 'system', subtype: 'session_state_changed', state: value });

test('a result before idle keeps input open so steering still reaches Claude', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield state('running');
    yield turn;
    // Claude Code keeps working after this result until it reports idle.
    await new Promise(setImmediate);
    context.handleInputLine(JSON.stringify({ type: 'steer_prompt', request_id: 1, prompt: 'change course' }));
    assert.equal(events.find(e => e.request_id === 1)?.accepted, true);
    assert.equal((await input.next()).value.message.content[0].text, 'change course');
    yield turn;
    yield state('idle');
    assert.equal((await input.next()).done, true);
  } }, { prompt: 'test' });
});

test('a steer between the result and idle keeps input open for its reply', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield state('running');
    yield turn;
    context.handleInputLine(JSON.stringify({ type: 'steer_prompt', request_id: 2, prompt: 'one more thing' }));
    assert.equal(events.find(e => e.request_id === 2)?.accepted, true);
    // This idle predates the steer, so it must not end the input.
    yield state('idle');
    assert.equal((await input.next()).value.message.content[0].text, 'one more thing');
    yield state('running');
    yield turn;
    yield state('idle');
    assert.equal((await input.next()).done, true);
  } }, { prompt: 'test' });
});

test('a steer backgrounds blocking tools and arrives as its own turn', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  let backgroundCalls = 0;
  const run = (async function* ({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield state('running');
    // A foreground wait loop is running; the steer must not queue behind it.
    context.handleInputLine(JSON.stringify({ type: 'steer_prompt', request_id: 3, prompt: 'stop and answer me' }));
    assert.equal(events.find(e => e.request_id === 3)?.accepted, true);
    assert.equal(backgroundCalls, 1);
    const steer = (await input.next()).value;
    assert.equal(steer.priority, 'now');
    assert.equal(steer.message.content[0].text, 'stop and answer me');
    yield turn;
    yield state('idle');
    assert.equal((await input.next()).done, true);
  });
  await context.handleClaudeSendPrompt({ query(args) {
    const generator = run(args);
    generator.backgroundTasks = async () => { backgroundCalls += 1; return true; };
    return generator;
  } }, { prompt: 'test' });
});

test('a steer is still accepted when backgrounding fails', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  const run = (async function* ({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield state('running');
    context.handleInputLine(JSON.stringify({ type: 'steer_prompt', request_id: 4, prompt: 'hello?' }));
    assert.equal(events.find(e => e.request_id === 4)?.accepted, true);
    assert.equal((await input.next()).value.message.content[0].text, 'hello?');
    yield turn;
    yield state('idle');
    assert.equal((await input.next()).done, true);
  });
  await context.handleClaudeSendPrompt({ query(args) {
    const generator = run(args);
    generator.backgroundTasks = async () => { throw new Error('background tasks disabled'); };
    return generator;
  } }, { prompt: 'test' });
});

test('a turn cut by back-to-back steers is not a failure', { timeout: 2000 }, async () => {
  const { context, events } = bridge();
  const preempted = { type: 'result', subtype: 'error_during_execution', is_error: true, errors: ['[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null'] };
  await context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield state('running');
    context.handleInputLine(JSON.stringify({ type: 'steer_prompt', request_id: 5, prompt: 'child A finished' }));
    context.handleInputLine(JSON.stringify({ type: 'steer_prompt', request_id: 6, prompt: 'child B finished' }));
    yield { type: 'result', subtype: 'success', result: '' };
    yield preempted;
    yield { type: 'result', subtype: 'success', result: 'both children are done' };
    yield state('idle');
  } }, { prompt: 'test' });
  assert.equal(events.at(-1).type, 'result');
  assert.equal(events.at(-1).reply_text, 'both children are done');
});

test('a diagnostic-only error with no steer still fails the turn', { timeout: 2000 }, async () => {
  const { context } = bridge();
  await assert.rejects(context.handleClaudeSendPrompt({ async *query({ prompt }) {
    const input = prompt[Symbol.asyncIterator]();
    await input.next();
    yield { type: 'result', subtype: 'error_during_execution', is_error: true, errors: ['[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null'] };
  } }, { prompt: 'test' }), /ede_diagnostic/);
});

test('Claude is asked to report session state', () => {
  const { context } = bridge();
  assert.equal(context.buildClaudeOptions({}).env.CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS, '1');
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

for (const [label, info, expected] of [
  ['signed out', { tokenSource: 'none', apiProvider: 'firstParty' }, 'signed_out'],
  ['no account', null, 'signed_out'],
  ['OAuth login', { tokenSource: 'claude.ai', apiProvider: 'firstParty' }, 'signed_in'],
  ['API key', { tokenSource: 'none', apiKeySource: 'ANTHROPIC_API_KEY', apiProvider: 'firstParty' }, 'signed_in'],
  ['Bedrock', { apiProvider: 'bedrock' }, 'signed_in'],
]) {
  test(`auth check reports ${expected} for ${label} without starting a turn`, { timeout: 2000 }, async () => {
    const events = [];
    const context = vm.createContext({ setTimeout, clearTimeout, process: { env: {}, stdout: { write: line => events.push(JSON.parse(line)) } } });
    vm.runInContext(source, context);
    let options = null;
    let promptYielded = false;
    let closed = false;
    const sdk = { query(params) {
      options = params.options;
      (async () => { for await (const _ of params.prompt) promptYielded = true; })();
      return { accountInfo: async () => info, close: () => { closed = true; } };
    } };
    await context.handleClaudeAuth(sdk, { cwd: '/tmp' });
    await new Promise(setImmediate);
    assert.equal(events.at(-1).state, expected);
    assert.equal(options.persistSession, false, 'auth checks must not write a session transcript');
    assert.equal(promptYielded, false, 'auth checks must not send a prompt');
    assert.equal(closed, true);
  });
}

test('plan rate limit covered by usage credits does not fail the turn', () => {
  const { context } = bridge();
  const event = info => ({ type: 'rate_limit_event', rate_limit_info: info });
  const check = context.claudeRejectedRateLimitMessage;
  assert.equal(check(event({ status: 'rejected', rateLimitType: 'seven_day', overageStatus: 'allowed' })), null);
  assert.equal(check(event({ status: 'rejected', rateLimitType: 'five_hour', overageStatus: 'allowed_warning' })), null);
  assert.equal(check(event({ status: 'rejected', rateLimitType: 'seven_day', isUsingOverage: true })), null);
  assert.equal(check(event({ status: 'rejected', rateLimitType: 'seven_day', overageStatus: 'rejected', overageDisabledReason: 'out_of_credits' })), 'Claude seven_day usage limit has been reached.');
  assert.equal(check(event({ status: 'rejected', rateLimitType: 'seven_day' })), 'Claude seven_day usage limit has been reached.');
  assert.equal(check(event({ status: 'rejected', rateLimitType: 'overage', overageStatus: 'allowed' })), 'Claude overage usage limit has been reached.');
  assert.equal(check(event({ status: 'allowed_warning', rateLimitType: 'seven_day' })), null);
});

for (const explicit of [false, true]) {
  test(`Fable 5.2 remains selectable after model discovery (explicit=${explicit})`, async () => {
    const { context, events } = bridge();
    const efforts = ['low', 'medium', 'high', 'xhigh', 'max'];
    const models = [
      { value: 'default', displayName: 'Default (Opus 5.5)', supportsEffort: true },
      { value: 'fable[1m]', displayName: 'Fable 5.1', supportsEffort: true },
      ...(explicit ? [{ value: 'claude-fable-5-2', displayName: 'Fable 5.2', supportsEffort: true, supportedEffortLevels: efforts }] : []),
    ];
    let closed = false;
    await context.handleClaudeListModels({ query() {
      return { supportedModels: async () => models, close: () => { closed = true; } };
    } }, {});
    const listed = events.at(-1).models;
    assert.equal(closed, true);
    assert.equal(listed[0].id, 'default');
    assert.equal(listed[0].name, 'Default (Opus 5.5)');
    assert.equal(listed.filter(model => model.id === 'claude-fable-5-2').length, 1);
    assert.deepEqual(listed.find(model => model.id === 'claude-fable-5-2'), {
      id: 'claude-fable-5-2', name: 'Fable 5.2', reasoning_supported: true, supported_effort_levels: efforts,
    });
    assert.ok(listed.some(model => model.id === 'fable[1m]'));
    assert.equal(context.buildClaudeOptions({ model: 'claude-fable-5-2', reasoning_effort: 'max' }).model, 'claude-fable-5-2');
  });
}

for (const models of [[], null]) {
  test(`empty Claude discovery preserves client fallback (${JSON.stringify(models)})`, async () => {
    const { context, events } = bridge();
    await context.handleClaudeListModels({ query() {
      return { supportedModels: async () => models, close() {} };
    } }, {});
    assert.deepEqual(events.at(-1).models, []);
  });
}
