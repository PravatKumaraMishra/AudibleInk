"""Install an engine's pinned libraries on first synthesis, outside the app bundle."""
import fcntl
import hashlib
import importlib
import json
import os
from pathlib import Path
import shutil
import signal
import site
import subprocess
import sys
import tempfile

ENGINES = frozenset(('kokoro', 'soprano', 'svara', 'indicf5'))


def engine_directory(engine, lock):
    identity = hashlib.sha256(lock.read_bytes() + sys.version.encode() + b'engine-layout-1').hexdigest()[:16]
    home = Path(os.environ.get('AUDIBLEINK_ENGINE_HOME',
        str(Path.home() / 'Library/Application Support/AudibleInk/engines')))
    return home, home / f'{engine}-{identity}'


def run_installer(command, **kwargs):
    process = subprocess.Popen(command, start_new_session=True, **kwargs)
    previous = signal.getsignal(signal.SIGTERM)
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    try:
        return subprocess.CompletedProcess(command, process.wait())
    finally:
        signal.signal(signal.SIGTERM, previous)
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            except ProcessLookupError:
                pass


def ensure_engine(engine, progress=None):
    if engine not in ENGINES:
        raise ValueError('Unknown speech engine')
    # Development environments already install requirements.lock. Releases have
    # an explicit marker and never install into their signed, read-only bundle.
    if not (Path(sys.prefix) / 'audibleink-runtime.json').is_file() and os.environ.get('AUDIBLEINK_LAZY_DEPENDENCIES') != '1':
        return
    lock = Path(__file__).parent / 'requirements' / f'{engine}.lock'
    home, destination = engine_directory(engine, lock)
    if str(destination) in sys.path and (destination / '.complete').is_file():
        return
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    if progress:
        progress(f'Preparing {engine} libraries…')
    with (home / f'.{engine}.lock').open('a') as guard:
        # flock is released by the OS even if Stop, Quit, or a crash kills us.
        fcntl.flock(guard, fcntl.LOCK_EX)
        if not (destination / '.complete').is_file():
            if progress:
                progress(f'Installing {engine} libraries for first use. Internet required…')
            # Only this engine can own these temporary directories under its lock.
            for abandoned in home.glob(f'.{engine}-install-*'):
                if abandoned.is_dir() and not abandoned.is_symlink():
                    shutil.rmtree(abandoned)
            with tempfile.TemporaryDirectory(prefix=f'.{engine}-install-', dir=home) as temporary:
                staging = Path(temporary) / 'packages'
                environment = dict(os.environ, PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1')
                environment.pop('PYTHONPATH', None)
                environment.pop('PYTHONHOME', None)
                command = [sys.executable, '-m', 'pip', '--isolated', '--disable-pip-version-check',
                           'install', '--no-input', '--no-deps', '--no-compile', '--no-warn-script-location',
                           '--only-binary=:all:', '--target', str(staging), '-r', str(lock)]
                # IndicF5 and jieba are pure-Python source distributions. Build
                # their wheels with pip; neither requires Git or a compiler.
                command.insert(command.index('--target'), '--no-binary=indic-f5-mlx,jieba,docopt')
                log = Path(temporary) / 'install.log'
                with log.open('w') as output:
                    result = run_installer(command, stdout=output, stderr=subprocess.STDOUT, env=environment)
                if result.returncode:
                    detail = log.read_text(errors='replace')[-1800:]
                    raise RuntimeError(f'{engine} setup did not finish. Check your internet connection and try Start again. ' + detail)
                (staging / '.complete').write_text(json.dumps({'engine': engine, 'lock': destination.name}))
                if destination.exists():
                    shutil.rmtree(destination)
                os.replace(staging, destination)
    # addsitedir handles any package .pth files, then prioritize this engine's
    # libraries over development or system Python installations.
    site.addsitedir(str(destination))
    if str(destination) in sys.path:
        sys.path.remove(str(destination))
    sys.path.insert(0, str(destination))
    importlib.invalidate_caches()
    if progress:
        progress(f'Loading {engine}; downloading model files if needed…')
