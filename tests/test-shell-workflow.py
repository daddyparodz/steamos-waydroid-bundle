#!/usr/bin/env python3
"""Exercise the workflow's actual dependency and test execution blocks."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/shell-check.yml'


def block(name):
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index('      - name: ' + name)
    run = next(i for i in range(start + 1, len(lines)) if lines[i] == '        run: |')
    result = []
    for line in lines[run + 1:]:
        if line and not line.startswith('          '):
            break
        result.append(line[10:] if line else '')
    return '\n'.join(result) + '\n'


class WorkflowTests(unittest.TestCase):
    def test_bootstrap_installs_fixture_dependencies(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            apt = path / 'apt-get'
            apt.write_text('''#!/bin/bash
printf "%s\\n" "$*" >> "$APT_LOG"
if [[ "$1" == install ]]; then
    if [[ "${DEBIAN_FRONTEND:-}" != noninteractive || "${TZ:-}" != Etc/UTC ]]; then
        echo 'debconf: Geographic area:' >&2
        touch "$INPUT_READ"
        read -r -t 0.1 answer || true
        exit 86
    fi
fi
''')
            apt.chmod(0o755)
            env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'],
                       APT_LOG=str(path / 'apt.log'), INPUT_READ=str(path / 'input-read'))
            # Apply the real step metadata, never a separately invented safe environment.
            env.pop('DEBIAN_FRONTEND', None)
            env.pop('TZ', None)
            text = WORKFLOW.read_text()
            step = text.split('      - name: Install analysis tools\n', 1)[1].split('      - name:', 1)[0]
            metadata = step.split('        run: |', 1)[0]
            in_env = False
            for line in metadata.splitlines():
                if line == '        env:':
                    in_env = True
                elif in_env and line.startswith('          '):
                    key, value = line.strip().split(': ', 1)
                    env[key] = value
                else:
                    in_env = False
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', block('Install analysis tools')],
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((path / 'input-read').exists(), 'debconf attempted to read input')
            self.assertEqual(env.get('DEBIAN_FRONTEND'), 'noninteractive')
            self.assertEqual(env.get('TZ'), 'Etc/UTC')
            self.assertEqual(text.count('DEBIAN_FRONTEND:'), 1)
            self.assertEqual(text.count('TZ:'), 1)
            self.assertIn('        timeout-minutes: 10\n', metadata)
            self.assertIn('    timeout-minutes: 30\n', text.split('    steps:', 1)[0])
            packages = (path / 'apt.log').read_text().split()
            for package in ('shellcheck', 'shfmt', 'ripgrep', 'python3', 'coreutils', 'util-linux'):
                self.assertIn(package, packages)

    def test_execution_drops_root_and_preserves_all_entrypoints(self):
        shell = block('Run uninstall failure-path tests')
        self.assertIn('runuser -u ubuntu --', shell)
        self.assertIn('env -u SUDO_USER', shell)
        self.assertIn('bash -euo pipefail', shell)
        expected = {str(p.relative_to(ROOT)).replace('\\', '/') for p in (ROOT / 'tests').glob('test-*.sh')}
        actual = {line.strip() for line in shell.splitlines() if line.strip().startswith('tests/test-') and line.strip().endswith('.sh')}
        self.assertEqual(expected, actual)
        self.assertEqual(len(actual), 12)

    def test_actual_test_block_propagates_first_failure(self):
        # Replace only the OS identity boundary; project children remain real processes.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'tests').mkdir()
            for index, script in enumerate(sorted((ROOT / 'tests').glob('test-*.sh'))):
                child = path / 'tests' / script.name
                child.write_text('#!/bin/bash\nexit ' + ('19' if index == 0 else '0') + '\n')
                child.chmod(0o755)
            for name, body in {
                'chown': 'exit 0',
                'python3': 'exit 0',
                'runuser': '[[ "$1 $2 $3" == "-u ubuntu --" ]] || exit 90; shift 3; exec "$@"',
            }.items():
                child = path / name
                child.write_text('#!/bin/bash\n' + body + '\n')
                child.chmod(0o755)
            env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], GITHUB_WORKSPACE=tmp)
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', block('Run uninstall failure-path tests')], cwd=tmp, env=env)
            self.assertEqual(result.returncode, 19)

    def test_checkout_is_readonly_and_exact(self):
        text = WORKFLOW.read_text()
        self.assertIn('  contents: read\n', text)
        self.assertIn('          persist-credentials: false\n', text)
        self.assertIn('          ref: ${{ github.event.pull_request.head.sha || github.sha }}\n', text)

    def test_real_profile_home_matches_fixture_only_when_nonroot(self):
        if os.name != 'posix':
            self.skipTest('Linux identity proof')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            getent = path / 'getent'
            getent.write_text('#!/bin/bash\nprintf "deck:x:1000:1000::/synthetic/deck:/bin/bash\\n"\n')
            getent.chmod(0o755)
            env = dict(os.environ, HOME=tmp, PATH=tmp + ':' + os.environ['PATH'])
            env.pop('SUDO_USER', None)
            helper = path / 'profile.sh'
            helper.write_text((ROOT / 'libexec/steamos-waydroid/waydroid-profile.sh').read_text())
            result = subprocess.check_output(['bash', '-c', 'source "$1"; waydroid_user_home', 'bash', str(helper)], env=env, text=True).strip()
            self.assertEqual(result, '/synthetic/deck' if os.geteuid() == 0 else tmp)
            self.assertEqual(result == tmp, os.geteuid() != 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
