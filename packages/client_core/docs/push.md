# K-17 push decrypt, registration and attention

This covers the mobile side of A-12/A-14 push. The daemon seals a small
payload to a per-device X25519 key (`packages/headless/src/push_seal.zig`), and
the relay forwards only the opaque envelope. The core owns three pieces:

- `vc_push_open`, a pure decrypt function that needs no host handle and is
  small enough for the iOS Notification Service Extension;
- the `push_register` intent, which keeps the host's push key and calls
  `device.push.register`;
- the per-thread attention state machine and the `attention` query.

## Push key record

`vc/1/<host_id>/push` holds versioned JSON in `value_base64`:

```json
{"version":1,"runtime_id":"<32 hex>","public_key":"<43 b64url>","secret_key":"<43 b64url>"}
```

Keys are canonical unpadded base64url. A record is used only when the public
key matches the one recovered from the secret and `runtime_id` matches the
paired runtime. Sign-out and `forget_host` delete it (see auth.md).

There is one key per host profile, not one per device. The platform supplies
32 random bytes in `key_seed_base64`, and the core derives the key pair from
them only when no valid record exists. Keeping keys per host means removing one
host never breaks another host's notifications, and a re-paired runtime gets a
new key. The platform has to give the NSE read access to these records (App
Group keychain on iOS). Android decrypts in-process.

## `push_register`

```json
{"type":"push_register","intent_id":"...","platform":"android|ios",
 "send_token":"<relay send token>","key_seed_base64":"<32 bytes, base64>"}
```

The shapes match the daemon's validation: the platform is `android` or `ios`,
the token is 1-4096 bytes of printable non-space ASCII, and the seed decodes to
exactly 32 bytes. Anything else is rejected before a receipt. The intent needs
the `device:write` scope, an online host and no removal in progress, and only
one registration runs at a time. The failure codes are
`insufficient_scope`, `unavailable`, `registration_in_progress`,
`push_key_unavailable` (storage) and `invalid_response`, plus RPC errors.

Flow: read the record, reuse it or write a new one, then send
`device.push.register {platform, send_token, public_key}`. The operation
succeeds when the reply is `{accepted:true}`. The send token and seed are never
persisted and are cleared from state as soon as the request is built. The
platform should call `push_register` after pairing, after every token refresh
and on app start (it is idempotent).

## `vc_push_open`

```c
vc_status vc_push_open(const unsigned char *json, size_t len, vc_buf *out);
```

JNI: `Native.pushOpen(ByteArray, IntArray): ByteArray?`. Request:

```json
{"api_version":1,"envelope":"<relay payload>",
 "keys":[{"host_id":"home","record_base64":"<stored vc/1/home/push value>"}],
 "recent":["home:turn-1:completed"]}
```

The platform passes every stored push record, because the relay payload does
not say which host sent it. The core tries each record. `recent` is the
platform's small ring of dedupe keys it has already shown. The request is at
most 64 KiB, with at most 32 keys and 256 recent entries. Status codes are
returned only for malformed requests (1) and `api_version` ≠ 1 (2). Every
decrypt or payload problem instead returns a displayable `PushNotification`:

| field | meaning |
|---|---|
| `opened` | the envelope authenticated and the payload was valid |
| `update_required` | the envelope version is newer than this build |
| `error` | `null`, `no_key`, `authentication_failed`, `unsupported_version`, `invalid_envelope`, `envelope_too_large`, `invalid_payload` |
| `host_id`, `workspace_id`, `thread_id`, `turn_id` | target, null when unopened |
| `kind` | daemon kind, or `generic` |
| `attention` | `unread`, `needs_approval`, `blocked`, `failed` or null |
| `channel` | `attention` (approval, input, failure) or `completed` |
| `title`, `body` | display text (title ≤120, snippet ≤200 code points, controls removed) |
| `deep_link` | `verde://open?host_id=…&workspace_id=…&thread_id=…` (percent-encoded) |
| `actions` | `open`, plus `approve`/`deny` (approval) or `reply` (completed, input needed) |
| `dedupe_key` | `<host_id>:<turn_id>:<kind>`, matching the daemon's `turn_id:kind` per host |
| `duplicate` | `dedupe_key` is in `recent`; the platform should suppress it |

When the envelope cannot be opened, the result is the generic
`Verde` / `A Verde chat needs attention` model that deep-links to `verde://open`.
A payload whose `runtime_id` differs from the record's runtime is treated as
invalid even if it decrypts. The kind aliases `done` and `approval` normalize to
`completed` and `approval_pending`. The `test` kind has no dedupe key.

All work uses a fixed 512 KiB scratch buffer that is zeroed afterwards, along
with the decoded secrets and plaintext. Nothing is logged.

The approve and deny actions carry no `call_id` (the payload does not include
one). The platform resolves them by opening the thread and reading its pending
approval, or it just opens the app. Only `approval_decide` sends a decision.

## Attention

The core keeps one entry per catalog thread in `vc/1/<host_id>/attention`
(`{version:1,entries:[{workspace_id,thread_id,turn_id,status,attention,since_ms}]}`).
It loads lazily once a sync snapshot exists and is written back after changes.
It ports `notify.ts`:

- `notificationStatus` maps a turn status plus pending approval to
  `idle | working | done | waiting | error`.
- `advanceAttention` raises attention on working→done/waiting/error and on
  waiting→done/error. A new turn that is already settled between two
  observations counts as having been working. Attention is kept while the
  status is unchanged, and cleared on new work, on idle, or when the thread is
  in view.
- `blocked` (input needed) is only known from push and is kept while its turn
  is still running.

A thread is in view when it is the focused thread (`focus` or `thread_open`)
and the host is in the foreground. Attention is not raised for that thread and
is cleared on view. The observed state is the latest sync-snapshot turn for the
thread, overridden by the chat engine's live turn and approval for open
threads. Seeding (the first observation or a first load) never raises. Nothing
advances while `turns`/`workspaces` are listed in `incomplete_scopes`.

A raised transition emits one `notify` effect. Its `notification_id` is the
same dedupe key as `vc_push_open`, so a platform that remembers shown IDs does
not show both a local and a remote notice. In-memory IDs are bounded to 64.

`push_received {workspace_id, thread_id, turn_id, kind}` tells the core about a
push the platform opened while the host is loaded. It updates attention
without emitting another `notify`.

Queries:

- `attention` returns `{items:[AttentionItem], count, loading}`, newest first,
  where `AttentionItem` is `{workspace_id, thread_id, turn_id, kind, status,
  since_ms, title, deep_link}`.
- `home` and `workspaces` chat panes get `attention:true` and
  `attention_kind`. `home` also lists unread panes of open workspaces.

`state_changed` lists `attention` whenever chat or sync scopes change.
