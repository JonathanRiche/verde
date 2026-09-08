#!/usr/bin/env python3
"""Exercise Settings' installer shell with local fixtures; never update the host."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'packages/desktop/src/app/update_installer.zig'
BLOCK = SOURCE.read_text().split('pub const TERMINAL_INSTALL_SCRIPT =', 1)[1].split('\n;', 1)[0]
SCRIPT = '\n'.join(line.strip()[2:] for line in BLOCK.splitlines() if line.strip().startswith('\\\\'))


class UpdateInstallerTest(unittest.TestCase):
    def run_installer(self, platform, executable, download_status=0, install_status=0):
        with tempfile.TemporaryDirectory(prefix='verde-update-test-') as directory:
            root = Path(directory)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            scratch = root / 'tmp'
            scratch.mkdir()
            for name, contents in {
                'uname': '#!/bin/sh\nprintf "%s\\n" "$TEST_PLATFORM"\n',
                'curl': '''#!/bin/sh
exit_status="$TEST_DOWNLOAD_STATUS"
[ "$exit_status" = 0 ] || exit "$exit_status"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    cat > "$1" <<'INSTALL'
printf '%s\\n%s\\n' "${VERDE_INSTALL_PREFIX:-}" "${VERDE_MACOS_APP_DIR:-}" > "$TEST_RESULT"
exit "$TEST_INSTALL_STATUS"
INSTALL
    exit 0
  fi
  shift
done
exit 90
''',
            }.items():
                path = bin_dir / name
                path.write_text(contents)
                path.chmod(0o755)
            result_path = root / 'result'
            env = dict(os.environ)
            for key in ('VERDE_INSTALL_PREFIX', 'VERDE_MACOS_APP_DIR'):
                env.pop(key, None)
            env.update(PATH=f'{bin_dir}:/usr/bin:/bin', TMPDIR=str(scratch),
                       TEST_PLATFORM=platform, TEST_RESULT=str(result_path),
                       TEST_DOWNLOAD_STATUS=str(download_status), TEST_INSTALL_STATUS=str(install_status))
            result = subprocess.run(['sh', '-c', SCRIPT, 'verde-update', executable],
                                    env=env, capture_output=True, text=True, timeout=10)
            recorded = result_path.read_text().splitlines() if result_path.exists() else None
            self.assertEqual(list(scratch.iterdir()), [], 'temporary download must be cleaned up')
            return result, recorded

    def test_linux_library_replacement_preserves_running_mapping(self):
        source = (ROOT / 'scripts/release/install-linux-local.sh').read_text()
        function = source.split('copy_glob_if_present() {', 1)[1].split('\n}', 1)[0]
        with tempfile.TemporaryDirectory(prefix='verde-update-library-') as directory:
            root = Path(directory)
            package = root / 'package'
            installed = root / 'installed'
            package.mkdir()
            installed.mkdir()
            (package / 'libSDL3_ttf.so.0').write_bytes(b'new library')
            target = installed / 'libSDL3_ttf.so.0'
            target.write_bytes(b'old library')
            # An open descriptor retains the inode just as a running loader does.
            with target.open('rb') as running_library:
                result = subprocess.run(
                    ['bash', '-c', 'copy_glob_if_present() {' + function + '\n}\ncopy_glob_if_present "$1" "$2"',
                     'test', str(package / 'libSDL3_ttf.so*'), str(installed)],
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(running_library.read(), b'old library')
                self.assertEqual(target.read_bytes(), b'new library')

    def test_linux_custom_prefix_and_shell_metacharacters(self):
        result, recorded = self.run_installer('Linux', "/tmp/custom ' $(false)/bin/verde-gui")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(recorded, ["/tmp/custom ' $(false)", ''])
        self.assertIn('Update complete', result.stdout)

    def test_macos_updates_running_bundle_directory(self):
        result, recorded = self.run_installer('Darwin', '/Volumes/My Apps/Verde.app/Contents/MacOS/verde-gui')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(recorded, ['', '/Volumes/My Apps'])

    def test_unbundled_macos_uses_installer_defaults(self):
        result, recorded = self.run_installer('Darwin', '/tmp/build/bin/verde-gui')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(recorded, ['', ''])

    def test_download_failure_never_runs_installer(self):
        result, recorded = self.run_installer('Linux', '/tmp/prefix/bin/verde-gui', download_status=22)
        self.assertEqual(result.returncode, 22)
        self.assertIsNone(recorded)
        self.assertNotIn('Update complete', result.stdout)

    def test_installer_failure_is_preserved(self):
        result, _ = self.run_installer('Darwin', '/Applications/Verde.app/Contents/MacOS/verde-gui', install_status=13)
        self.assertEqual(result.returncode, 13)
        self.assertNotIn('Update complete', result.stdout)


if __name__ == '__main__':
    unittest.main()
