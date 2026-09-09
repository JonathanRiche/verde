import { afterEach, expect, test } from 'bun:test'
import { chmod, mkdir, mkdtemp, readFile, readlink, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { installScript } from './curl-install-script'

const dirs: string[] = []
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

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
  for (const arch of ['arm64', 'x86_64']) {
    test(`macOS ${arch} installs the correct archive from ${format} metadata`, async () => {
      const { result, home, appDir, executable } = await runInstaller(json, arch)
      expect(result.stderr.toString()).not.toContain('could not find')
      expect(result.exitCode).toBe(0)
      expect(await readFile(join(appDir, 'Verde.app', 'Contents', 'VERSION'), 'utf8')).toBe('0.1.117')
      expect(await readlink(join(home, '.local', 'bin', 'verde'))).toBe(executable)
    })
  }
}

test('missing Mac asset fails without removing the installed app', async () => {
  const json = JSON.stringify({ ...metadata, assets: metadata.assets.slice(-1) })
  const { result, appDir } = await runInstaller(json, 'arm64')
  expect(result.exitCode).toBe(1)
  expect(result.stderr.toString()).toContain('could not find latest macOS arm64 release asset')
  expect(await readFile(join(appDir, 'Verde.app', 'old-version'), 'utf8')).toBe('preserve me')
})

async function runInstaller(json: string, arch: string) {
  const home = await mkdtemp(join(tmpdir(), 'verde-curl-test-'))
  dirs.push(home)
  const bin = join(home, 'tools')
  const appDir = join(home, 'Applications')
  const payload = join(home, 'payload')
  const executable = join(appDir, 'Verde.app', 'Contents', 'MacOS', 'verde')
  await mkdir(bin)
  await mkdir(join(appDir, 'Verde.app'), { recursive: true })
  await writeFile(join(appDir, 'Verde.app', 'old-version'), 'preserve me')
  await mkdir(join(payload, 'Verde.app', 'Contents', 'MacOS'), { recursive: true })
  await writeFile(join(payload, 'Verde.app', 'Contents', 'MacOS', 'verde'), '#!/bin/sh\n')
  await writeFile(join(payload, 'Verde.app', 'Contents', 'VERSION'), '0.1.117')
  const zip = Bun.spawnSync(['zip', '-qr', join(home, 'payload.zip'), 'Verde.app'], { cwd: payload })
  expect(zip.exitCode).toBe(0)
  await writeFile(join(home, 'release.json'), json)
  await writeFile(join(bin, 'uname'), '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo "$TEST_ARCH";; esac\n')
  await writeFile(join(bin, 'curl'), `#!/bin/sh
case "$*" in
  *api.github.com*) cat "$HOME/release.json" ;;
  *)
    case "$*" in
      *"https://example.invalid/verde-v0.1.117-macos-$TEST_ARCH.zip "*) ;;
      *) echo "wrong download: $*" >&2; exit 9 ;;
    esac
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then cp "$HOME/payload.zip" "$2"; exit; fi
      shift
    done
    exit 10 ;;
esac
`)
  await chmod(join(bin, 'uname'), 0o755)
  await chmod(join(bin, 'curl'), 0o755)
  const result = Bun.spawnSync(['sh', '-c', installScript], {
    env: {
      HOME: home, PATH: `${bin}:/usr/bin:/bin`, SHELL: '/bin/zsh',
      VERDE_MACOS_APP_DIR: appDir, TEST_ARCH: arch,
    },
    timeout: 10_000,
  })
  return { result, home, appDir, executable }
}
