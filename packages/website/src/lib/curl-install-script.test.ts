import { afterEach, expect, test } from 'bun:test'
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { installScript } from './curl-install-script'

const assetNames = [
  'linux-x86_64.tar.gz', 'macos-arm64.dmg', 'macos-arm64.zip',
  'macos-x86_64.dmg', 'macos-x86_64.zip', 'windows-x86_64.zip.sha256',
]
const metadata = {
  tag_name: 'v0.1.117',
  assets: assetNames.map((name) => ({
    browser_download_url: `https://example.invalid/verde-v0.1.117-${name}`,
  })),
  body: 'Notes with "browser_download_url":"https://example.invalid/fake-macos-arm64.zip"',
}

for (const [format, json] of Object.entries({
  pretty: JSON.stringify(metadata, null, 2),
  compact: JSON.stringify(metadata),
  wrapped: JSON.stringify(metadata, null, 2).replaceAll(': ', ':\n'),
  escaped: JSON.stringify(metadata).replaceAll('/', '\\/'),
})) {
  test(`selects the Linux archive and version from ${format} metadata`, () => {
    // Run the actual installer's definitions without downloading or installing.
    const definitions = installScript.slice(0, installScript.indexOf('os="$(uname -s)"'))
    const result = Bun.spawnSync(['sh', '-c', `${definitions}
latest_tag_from_json
asset_url_for 'verde-.+-linux-x86_64[.]tar[.]gz$'
`], { env: { PATH: '/usr/bin:/bin', HOME: '/tmp', RELEASE_JSON: json }, timeout: 10_000 })
    expect(result.exitCode).toBe(0)
    expect(result.stdout.toString().trim().split('\n')).toEqual([
      'v0.1.117', 'https://example.invalid/verde-v0.1.117-linux-x86_64.tar.gz',
    ])
  })
}

const tempDirs: string[] = []

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { force: true, recursive: true })))
})

async function tempDir() {
  const dir = await mkdtemp(join(tmpdir(), 'verde-curl-install-test-'))
  tempDirs.push(dir)
  return dir
}

/** Writes executable stubs into a fresh bin dir that shadows the host commands. */
async function stubBin(root: string, stubs: Record<string, string>) {
  const bin = join(root, 'stub-bin')
  await mkdir(bin, { recursive: true })
  for (const [name, body] of Object.entries(stubs)) {
    await writeFile(join(bin, name), `#!/bin/sh\n${body}\n`)
    await chmod(join(bin, name), 0o755)
  }
  return bin
}

const definitions = installScript.slice(0, installScript.indexOf('os="$(uname -s)"'))
const allWpeLibs = `printf '\\tlibWPEWebKit-2.0.so.1 (libc6,x86-64) => /usr/lib/libWPEWebKit-2.0.so.1\\n\\tlibsoup-3.0.so.0 (libc6,x86-64) => /usr/lib/libsoup-3.0.so.0\\n'`

test('continues when every WPE runtime library is already installed', async () => {
  const root = await tempDir()
  const bin = await stubBin(root, { ldconfig: allWpeLibs })
  const result = Bun.spawnSync(['sh', '-c', `${definitions}
linux_install_wpe_runtime_if_requested
echo continued
`], { env: { PATH: `${bin}:/usr/bin:/bin`, HOME: root }, timeout: 10_000 })
  expect(result.stderr.toString()).toBe('')
  expect(result.exitCode).toBe(0)
  expect(result.stdout.toString()).toBe('continued\n')
})

test('falls back to the hint and continues when the package install fails', async () => {
  const root = await tempDir()
  const log = join(root, 'sudo.log')
  const bin = await stubBin(root, {
    // Never let the test reach a real package manager, even as root in CI.
    id: 'echo 1000',
    pacman: 'echo "pacman must run through sudo" >&2; exit 99',
    sudo: `printf '%s\\n' "$*" >> "${log}"; exit 1`,
  })
  const result = Bun.spawnSync(['sh', '-c', `${definitions}
linux_missing_wpe_runtime() { printf '%s\\n' libWPEWebKit-2.0.so.1; }
linux_install_wpe_runtime_if_requested
echo continued
`], {
    env: { PATH: `${bin}:/usr/bin:/bin`, HOME: root, VERDE_INSTALL_BROWSER_DEPS: '1' },
    timeout: 10_000,
  })
  const stdout = result.stdout.toString()
  expect(result.exitCode).toBe(0)
  expect(stdout).toContain('Could not install the browser runtime dependencies')
  expect(stdout).toContain('sudo pacman -S wpewebkit')
  expect(stdout.trimEnd().endsWith('continued')).toBe(true)
  expect(await readFile(log, 'utf8')).toMatch(/pacman -S --needed .*wpewebkit/)
})

test('explains a GitHub API failure instead of exiting silently', async () => {
  const root = await tempDir()
  const bin = await stubBin(root, {
    uname: '[ "$1" = -m ] && echo x86_64 || echo Linux',
    curl: 'echo "curl: (22) The requested URL returned error: 403" >&2; exit 22',
  })
  const result = Bun.spawnSync(['sh', '-c', installScript], {
    env: { PATH: `${bin}:/usr/bin:/bin`, HOME: root },
    timeout: 10_000,
  })
  expect(result.exitCode).toBe(1)
  expect(result.stderr.toString()).toContain('verde install: could not fetch the latest release')
})

/** Stubs uname/ldconfig/curl so the installer "downloads" a v9.9.9 package whose install-local.sh only writes bin/verde. */
async function linuxReleaseFixture(root: string) {
  const pkg = join(root, 'pkg', 'verde-v9.9.9-linux-x86_64')
  await mkdir(pkg, { recursive: true })
  await writeFile(join(pkg, 'install-local.sh'), 'mkdir -p "$1/bin" && printf "#!/bin/sh\\n" > "$1/bin/verde" && chmod 755 "$1/bin/verde"\n')
  const tarball = join(root, 'verde.tar.gz')
  expect(Bun.spawnSync(['tar', '-czf', tarball, '-C', join(root, 'pkg'), 'verde-v9.9.9-linux-x86_64']).exitCode).toBe(0)
  const json = join(root, 'latest.json')
  await writeFile(json, JSON.stringify({
    tag_name: 'v9.9.9',
    assets: [{ browser_download_url: 'https://example.invalid/verde-v9.9.9-linux-x86_64.tar.gz' }],
  }))
  return stubBin(root, {
    uname: '[ "$1" = -m ] && echo x86_64 || echo Linux',
    ldconfig: allWpeLibs,
    curl: `out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--retry|--retry-delay) shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$out" ]; then cp "${tarball}" "$out"; else cat "${json}"; fi`,
  })
}

test('installs on Linux with WPE present, quotes the path, and hints at PATH', async () => {
  const root = await tempDir()
  const prefix = join(root, 'my prefix')
  const bin = await linuxReleaseFixture(root)
  const result = Bun.spawnSync(['sh', '-c', installScript], {
    env: { PATH: `${bin}:/usr/bin:/bin`, HOME: root, VERDE_INSTALL_PREFIX: prefix },
    timeout: 20_000,
  })
  const stdout = result.stdout.toString()
  expect(result.stderr.toString()).toBe('')
  expect(result.exitCode).toBe(0)
  expect(stdout).toContain(`Done. Run Verde with: '${prefix}/bin/verde'`)
  expect(stdout).toContain(`export PATH='${prefix}/bin':"$PATH"`)
})

test('resolves a relative install prefix against the working directory', async () => {
  const root = await tempDir()
  const bin = await linuxReleaseFixture(root)
  const result = Bun.spawnSync(['sh', '-c', installScript], {
    cwd: root,
    env: { PATH: `${bin}:/usr/bin:/bin`, HOME: root, VERDE_INSTALL_PREFIX: './rel' },
    timeout: 20_000,
  })
  expect(result.exitCode).toBe(0)
  expect(result.stdout.toString()).toContain(`Installing Verde into ${root}/rel...`)
  expect(result.stdout.toString()).toContain(`export PATH="${root}/rel/bin:$PATH"`)
})

for (const [installed, force, message] of [
  ['9.9.8', '0', 'Upgrading Verde 9.9.8 → 9.9.9...'],
  ['9.10.0', '0', 'Downgrading Verde 9.10.0 → 9.9.9...'],
  ['v9.9.10', '0', 'Downgrading Verde 9.9.10 → 9.9.9...'],
  ['9.9.9', '1', 'Reinstalling Verde 9.9.9...'],
]) {
  test(`describes replacing ${installed} with 9.9.9 (force=${force})`, async () => {
    const root = await tempDir()
    const prefix = join(root, 'prefix')
    await mkdir(join(prefix, 'share', 'verde'), { recursive: true })
    await writeFile(join(prefix, 'share', 'verde', 'VERSION'), `${installed}\n`)
    const bin = await linuxReleaseFixture(root)
    const result = Bun.spawnSync(['sh', '-c', installScript], {
      env: { PATH: `${bin}:/usr/bin:/bin`, HOME: root, VERDE_INSTALL_PREFIX: prefix, VERDE_FORCE_INSTALL: force },
      timeout: 20_000,
    })
    expect(result.exitCode).toBe(0)
    expect(result.stdout.toString().split('\n')[0]).toBe(message)
  })
}

test('reports missing curl and wget before contacting GitHub', async () => {
  const root = await tempDir()
  // PATH holds only this stub dir, so neither curl nor wget is reachable.
  const bin = await stubBin(root, { uname: '[ "$1" = -m ] && echo x86_64 || echo Linux' })
  const result = Bun.spawnSync(['/bin/sh', '-c', installScript], {
    env: { PATH: bin, HOME: root },
    timeout: 10_000,
  })
  expect(result.exitCode).toBe(1)
  expect(result.stderr.toString()).toBe('verde install: missing required command: curl or wget\n')
})

test('explains an unset HOME instead of failing on an unbound variable', () => {
  const result = Bun.spawnSync(['sh', '-c', installScript], {
    env: { PATH: '/usr/bin:/bin' },
    timeout: 10_000,
  })
  expect(result.exitCode).toBe(1)
  expect(result.stderr.toString()).toBe('verde install: HOME is not set; set HOME to your home directory and retry\n')
})
