# Windows first-preview distribution decision

The first Windows x86-64 preview ships as a deterministic ZIP, not an MSI or
MSIX. This keeps the initial test artifact transparent and reversible while
native rendering, WebView2, ConPTY, process cleanup, and upgrade behavior are
still being validated on physical Windows machines.

The ZIP contains separate GUI and console entry points, their adjacent runtime
DLLs, checksums, a complete package manifest, dependency notices, and the
physical-machine test handoff. `install.ps1` copies the tree to
`%LOCALAPPDATA%\Programs\Verde` and creates a Start Menu shortcut whose
`System.AppUserModel.ID` is `Verde.Desktop`; the GUI process sets that same
identity before creating its first window.

From Linux or macOS, produce the unsigned internal-test artifact with:

```sh
mise run package-windows -- --version <version>
```

Pass `--skip-build --prefix-dir <path>` to package an already completed GNU
cross-build. The cross-host packager validates the pinned dependency manifest,
PE architecture/subsystems/resources, GUI/console split, package allowlists,
the exact compiled `BUILD_VERSION`, complete manifest/checksum coverage, and
the extracted tree. It also rejects injected files and the temporary
`fff_c.dll` stub used by compile-only checks. Authenticode release packaging
remains the responsibility of `package-windows.ps1` on a Windows signing host.

To assemble only the Windows npm runtime and the portable launcher from a
preview asset directory, use:

```sh
npm run package:npm -- --platform windows-x64 <version> <release-assets-dir> <output-dir>
```

Before a release, `scripts\dev\smoke-windows.ps1` can launch the GUI from an
absent persisted-state database, require the runtime to report zero workspaces
while opening the browser, wait through the console CLI for WebView2 to report
a ready native child view, verify a navigation-completed JavaScript evaluation,
and exercise the persistent terminal session. It writes cleanup/status evidence
below `.zig-cache\windows-smoke\evidence` and copies the pref-directory
`verde.stderr.log` there when that log exists. This is a startup-readiness gate,
not a substitute for physical D3D12 rendering, DPI, keyboard/IME,
pointer/clipboard, focus, overlay z-order, or repeated-lifecycle validation;
those remain in `WINDOWS-TESTING.md`.

Verde live and session control use current-logon named pipes and require no
firewall exception. Codex app-server and OpenCode use separate loopback-only
listeners on `127.0.0.1`; never expose them through a public/LAN inbound rule.
Windows Claude/Codex notification hooks are generated `.ps1` files invoked by
a child `powershell.exe` with process-scoped `-ExecutionPolicy Bypass`. The
installer does not change saved execution policy, and enterprise script policy
may still block these optional hooks. OpenCode and Cursor remain supported chat
providers even though they have no managed hook installer.

Manual, internal, and tag workflow builds may be unsigned, but they must carry
`WINDOWS-SIGNING.json` with `signed: false` and be distributed with the ZIP's
SHA-256 file through a trusted channel. When both signing secrets are
configured, tag releases instead require Authenticode signing and RFC 3161
timestamping. A stable installer is deferred until certificate ownership,
upgrade/downgrade behavior, uninstall cleanup, shortcut migration, and toast
activation are validated.

## GitHub Actions release flow

The repository does not run an automatic pull-request or `master`-push build.
The `Release` workflow is the build gate for Linux, both macOS architectures,
and Windows. Its Windows job uses the native MSVC toolchain on `windows-2022`,
compiles the Windows test targets, builds the package, and verifies the
extracted deterministic ZIP. Run `scripts\dev\smoke-windows.ps1` explicitly on
a Windows test host when runtime WebView2 and ConPTY readiness must be repeated
before tagging.

A manual Release dispatch is an unsigned rehearsal with a `manual-*` version;
it uploads artifacts but does not publish a GitHub release. Only a GitHub
`push` event for a `v*` tag can receive the Windows signing material and publish
the release. Signing is optional; configure both of these Actions repository
secrets together when ready to enable it:

- `WINDOWS_SIGNING_CERTIFICATE_BASE64`: base64-encoded Authenticode PFX.
- `WINDOWS_SIGNING_CERTIFICATE_PASSWORD`: password for that PFX.

Leaving both secrets unset publishes an explicitly unsigned Windows ZIP.
Configuring only one is treated as a release-configuration error.

Protect `v*` tags so only release maintainers can create them. The release is
published only after every Linux, macOS, and Windows artifact job succeeds.
