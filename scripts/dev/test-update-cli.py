#!/usr/bin/env python3
"""Run the built update CLI with local installer fixtures and temporary state."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve()


class UpdateCliTest(unittest.TestCase):
    def run_update(self, download_status=0, install_status=0, package_owned=False, json_output=True):
        with tempfile.TemporaryDirectory(prefix='verde-update-cli-') as directory:
            root = Path(directory)
            if sys.platform == 'darwin':
                prefix = root / 'Custom Apps'
                binary = prefix / 'Verde.app/Contents/MacOS/verde'
            else:
                prefix = root / "Custom ' Install"
                binary = prefix / 'bin/verde'
            binary.parent.mkdir(parents=True)
            shutil.copy2(BINARY, binary)
            fixtures = root / 'fixtures'
            fixtures.mkdir()
            marker = root / 'installed'
            scripts = {
                'curl': '''#!/bin/sh
[ "$TEST_DOWNLOAD_STATUS" = 0 ] || exit "$TEST_DOWNLOAD_STATUS"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    cat > "$1" <<'INSTALL'
echo 'Installer progress'
[ "$TEST_INSTALL_STATUS" = 0 ] || exit "$TEST_INSTALL_STATUS"
printf '%s' "${VERDE_MACOS_APP_DIR:-$VERDE_INSTALL_PREFIX}" > "$TEST_MARKER"
INSTALL
    exit 0
  fi
  shift
done
exit 90
''',
                'pacman': '#!/bin/sh\n[ "$TEST_PACKAGE_OWNED" = 1 ] || exit 1\nprintf "verde\\n"\n',
                'yay': '#!/bin/sh\nexit 99\n',
            }
            for name, content in scripts.items():
                path = fixtures / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ)
            for name in ('VERDE_MACOS_APP_DIR', 'VERDE_INSTALL_PREFIX'):
                env.pop(name, None)
            env.update(PATH=str(fixtures) + os.pathsep + env['PATH'],
                       TEST_DOWNLOAD_STATUS=str(download_status), TEST_INSTALL_STATUS=str(install_status),
                       TEST_PACKAGE_OWNED=str(int(package_owned)), TEST_MARKER=str(marker))
            command = [str(binary), 'update'] + (['--json'] if json_output else [])
            result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
            installed = marker.read_text() if marker.exists() else None
            return result, installed, str(prefix)

    def test_waits_for_installation_and_returns_clean_json(self):
        result, installed, prefix = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertTrue(response['ok'])
        self.assertEqual(response['result']['status'], 'installed')
        self.assertIsNotNone(installed)
        self.assertEqual(Path(installed).resolve(), Path(prefix).resolve())
        self.assertIn('Installer progress', result.stderr)

    def test_download_failure_is_nonzero_and_json_failure(self):
        result, installed, _ = self.run_update(download_status=22)
        self.assertEqual(result.returncode, 22, result.stderr)
        response = json.loads(result.stdout)
        self.assertFalse(response['ok'])
        self.assertEqual(response['error']['exit_code'], 22)
        self.assertIsNone(installed)

    def test_installer_failure_is_nonzero_and_json_failure(self):
        result, installed, _ = self.run_update(install_status=7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertFalse(json.loads(result.stdout)['ok'])
        self.assertIsNone(installed)

    def test_interactive_command_reports_installer_failure(self):
        result, installed, _ = self.run_update(install_status=7, json_output=False)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn('Installer progress', result.stdout)
        self.assertIn('Verde update failed', result.stderr)
        self.assertIsNone(installed)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'pacman ownership is Linux-only')
    def test_package_owned_install_returns_command_without_installing(self):
        result, installed, _ = self.run_update(package_owned=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response['result']['status'], 'package_manager_required')
        self.assertEqual(response['result']['command'], 'yay -Syu')
        self.assertIsNone(installed)


if __name__ == '__main__':
    unittest.main()
