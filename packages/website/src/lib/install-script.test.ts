import { afterEach, describe, expect, test } from 'bun:test'
import { chmod, mkdir, mkdtemp, readFile, readlink, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { macosInstallCliScript } from './install-script'

const tempDirs: string[] = []

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { force: true, recursive: true })))
})

describe('macOS curl installer', () => {
  test('links the CLI and adds the default zsh PATH once', async () => {
    const home = await mkdtemp(join(tmpdir(), 'verde-install-test-'))
    tempDirs.push(home)

    const appDir = join(home, 'Applications')
    const executable = join(appDir, 'Verde.app', 'Contents', 'MacOS', 'verde')
    await mkdir(join(appDir, 'Verde.app', 'Contents', 'MacOS'), { recursive: true })
    await writeFile(executable, '#!/bin/sh\n')
    await chmod(executable, 0o755)

    const shellScript = `set -eu
say() { printf '%s\\n' "$*"; }
${macosInstallCliScript}
macos_install_cli
macos_install_cli
`
    const result = Bun.spawnSync(['sh', '-c', shellScript], {
      env: {
        ...process.env,
        HOME: home,
        MACOS_APP_DIR: appDir,
        PATH: '/usr/bin:/bin',
        PREFIX: join(home, '.local'),
        SHELL: '/bin/zsh',
      },
    })

    expect(result.exitCode).toBe(0)
    expect(await readlink(join(home, '.local', 'bin', 'verde'))).toBe(executable)

    const zprofile = await readFile(join(home, '.zprofile'), 'utf8')
    expect(zprofile.match(/# Added by the Verde installer/g)).toHaveLength(1)
    expect(zprofile.match(/export PATH="\$HOME\/\.local\/bin:\$PATH"/g)).toHaveLength(1)
  })
})
