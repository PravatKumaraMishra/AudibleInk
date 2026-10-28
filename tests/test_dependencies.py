"""First-use installs must be atomic, retryable, and specific to one engine."""
from pathlib import Path
import os
import subprocess
import time
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from dependencies import ensure_engine, engine_directory


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / 'requirements').mkdir()
        for engine in ('kokoro', 'soprano', 'svara', 'indicf5'):
            (self.root / 'requirements' / f'{engine}.lock').write_text('example==1\n')
        self.patches = [
            patch('dependencies.__file__', str(self.root / 'dependencies.py')),
            patch.dict(os.environ, AUDIBLEINK_LAZY_DEPENDENCIES='1', AUDIBLEINK_ENGINE_HOME=str(self.root / 'engines')),
            patch.object(sys, 'path', list(sys.path)),
        ]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        self.temporary.cleanup()

    def install(self, command, **kwargs):
        self.assertIn('--isolated', command)
        self.assertNotIn('PYTHONPATH', kwargs['env'])
        target = Path(command[command.index('--target') + 1])
        target.mkdir()
        (target / 'example.py').write_text('ready=True\n')
        return types.SimpleNamespace(returncode=0)

    def test_only_requested_engine_installs_and_next_use_reuses_it(self):
        messages = []
        with patch('dependencies.run_installer', side_effect=self.install) as install:
            ensure_engine('kokoro', messages.append)
            ensure_engine('kokoro', messages.append)
        self.assertEqual(install.call_count, 1)
        command = install.call_args.args[0]
        self.assertTrue(command[-1].endswith('kokoro.lock'))
        ready = list((self.root / 'engines').glob('*/.complete'))
        self.assertEqual(len(ready), 1)
        self.assertTrue(any('Installing' in message for message in messages))
        self.assertFalse(list((self.root / 'engines').glob('soprano-*')))

    def test_failed_install_is_cleaned_up_and_can_be_retried(self):
        with patch('dependencies.run_installer', return_value=types.SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, 'try Start again'):
                ensure_engine('soprano')
        self.assertFalse(list((self.root / 'engines').glob('*/.complete')))
        self.assertFalse(list((self.root / 'engines').glob('.*-install-*')))
        with patch('dependencies.run_installer', side_effect=self.install):
            ensure_engine('soprano')
        self.assertEqual(len(list((self.root / 'engines').glob('*/.complete'))), 1)

    def test_changed_lock_gets_a_new_environment(self):
        lock = self.root / 'requirements/kokoro.lock'
        first = engine_directory('kokoro', lock)[1]
        lock.write_text('example==2\n')
        self.assertNotEqual(first, engine_directory('kokoro', lock)[1])

    def test_quitting_worker_stops_the_installer_and_cleans_staging(self):
        ready = self.root / 'installer-pid'
        fixture = f"import os,time; from pathlib import Path; Path({str(ready)!r}).write_text(str(os.getpid())); time.sleep(60)"
        code = f"""import sys
sys.path.insert(0, {str(Path(__file__).resolve().parents[1] / 'backend')!r})
import dependencies
dependencies.__file__ = {str(self.root / 'dependencies.py')!r}
original = dependencies.run_installer
def fixture(command, **kwargs):
    return original([sys.executable, '-c', {fixture!r}], **kwargs)
dependencies.run_installer = fixture
dependencies.ensure_engine('kokoro')
"""
        process = subprocess.Popen([sys.executable, '-c', code], env=os.environ.copy())
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue(ready.exists())
            installer_pid = int(ready.read_text())
            process.terminate()
            process.wait(timeout=10)
            with self.assertRaises(ProcessLookupError):
                os.kill(installer_pid, 0)
            self.assertFalse(list((self.root / 'engines').glob('*/.complete')))
            self.assertFalse(list((self.root / 'engines').glob('.*-install-*')))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_interrupted_install_never_becomes_ready(self):
        with patch('dependencies.run_installer', side_effect=OSError('interrupted')):
            with self.assertRaises(OSError):
                ensure_engine('svara')
        self.assertFalse(list((self.root / 'engines').glob('*/.complete')))
        with self.assertRaises(ValueError):
            ensure_engine('../../untrusted')
