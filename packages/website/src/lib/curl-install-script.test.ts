import { expect, test } from 'bun:test'
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

