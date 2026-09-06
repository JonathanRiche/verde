# Mobile pairing improvements plan

Friction observed while getting `verde-web` reachable from a phone over Tailscale
(dev build, `mise run web-app-run`). Three failed attempts before success:
`0.0.0.0` bind rejected → `TokenFileRequired` → manual token file + proxy origin.

Ranked by bang-for-buck.

## 1. Fix the two error messages (cheapest, biggest win)

- `non-loopback bind rejected; use --host 127.0.0.1 and connect through an SSH local forward`
  never mentions Tailscale. Anyone typing `0.0.0.0` wants remote access. Replace with:
  > verde-web only binds loopback. For remote access: `verde-server serve --tailscale`
  > (recommended), or `--trusted-proxy-origin https://<host>.ts.net` behind Tailscale Serve,
  > or an SSH local forward.
- `verde-web fatal: TokenFileRequired` is a bare enum name. Explain what a token file is and
  print the create recipe. `main.zig` `configurationErrorMessage` already exists; it returns
  `null` for `TokenFileRequired` — fill it in.

Files: `packages/web_app/src/main.zig`, `packages/web_app/src/config.zig`, tests alongside.

## 2. Auto-create the token file

If `--token-file` is omitted, generate an owner-only `web/token` under the data dir
(`--pref-path`, default `~/.local/share/verde/Native`) on first run and print where it lives
plus how to display it (`verde-web token show` or `cat`). The container image already does
exactly this on first start (`docs/daemon-deployment.md` ~L320), so this is consistent policy.
Keep explicit `--token-file` for control.

## 3. Auto-detect Tailscale Serve

On startup with no `--trusted-proxy-origin`, run `tailscale serve status --json`; if a mapping
to our port exists, print the exact flag to add — or adopt it via a `--tailscale` flag.
`verde-server serve --tailscale` already does this in the packaged binary; the gap is the dev
`zig-out` build. Add a `mise run web-app-serve-tailscale` task or wire `verde-server` into the
dev build.

## 4. Phone onboarding: QR code instead of pasting a 64-hex token

The pair URL (`verde://pair?host=…&grant_id=…#code=…`) already exists for desktop. Render it
as a terminal QR code so phone onboarding is scan → login. Token stays in the fragment, never
in logs/URLs.

## 5. Persistence

The dev command dies with the terminal. `verde-server serve` installs a systemd user unit;
add `mise run web-app-install-service` that writes
`~/.config/systemd/user/verde-web.service` with the working flags.

## 6. Session persistence on mobile (see investigation)

Re-entering the token every time the tab/PWA is closed. Investigate cookie lifetime /
`Max-Age` / SameSite / Secure on the session cookie issued by `POST /auth/session` in
trusted-proxy mode, and whether iOS/Android PWA cookie jars are dropping it.

## Working manual command (reference)

```sh
mkdir -p -m 700 ~/.local/share/verde/web
[ -f ~/.local/share/verde/web/token ] || openssl rand -hex 32 > ~/.local/share/verde/web/token
chmod 600 ~/.local/share/verde/web/token
mise run web-app-run -- --host 127.0.0.1 --port 6783 \
  --token-file ~/.local/share/verde/web/token \
  --trusted-proxy-origin https://richetech.tailc28f01.ts.net
```

### Resolution for item 6

Root cause: session cookie was `SameSite=Strict`. Mobile browsers treat PWA home-screen
launches and links from other apps as cross-site-initiated navigations and withhold Strict
cookies on the entry request, so `GET /` was always unauthenticated → `/login`.
Switched to `SameSite=Lax` (still blocks cross-site POST/fetch; Origin/Host envelope checks
remain). Remaining follow-up: sliding / longer TTL and on-disk session persistence.

### Resolution for item 6

Root cause: session cookie was `SameSite=Strict`. Mobile browsers treat PWA home-screen
launches and links from other apps as cross-site-initiated navigations and withhold Strict
cookies on the entry request, so `GET /` was always unauthenticated → `/login`.
Switched to `SameSite=Lax` (still blocks cross-site POST/fetch; Origin/Host envelope checks
remain). Remaining follow-up: sliding / longer TTL and on-disk session persistence.
