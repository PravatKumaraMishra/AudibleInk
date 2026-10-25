"""Download/warm the default model and verify the actual worker protocol."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
os.environ.setdefault('HF_HOME', str(Path.home() / 'Library/Caches/MarkdownVoice/huggingface'))
engine = 'qwen' if '--qwen' in sys.argv else 'kokoro'
start = time.monotonic()
worker = subprocess.Popen([sys.executable, '-u', str(root / 'backend/worker.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    for request in [
        {'id': 'prepare-test', 'command': 'prepare', 'text': '# Hello\n\nWelcome to **Murmur**.'},
        {'id': 'synth-test', 'command': 'synth', 'text': 'Welcome to Murmur. Your words stay on your Mac.', 'voice': 'Ryan' if engine == 'qwen' else 'af_heart', 'engine': engine, 'speed': 1.0},
    ]:
        worker.stdin.write(json.dumps(request) + '\n'); worker.stdin.flush()
        response = json.loads(worker.stdout.readline())
        if 'error' in response:
            raise RuntimeError(response['error'])
        if 'path' in response:
            import soundfile as sf
            audio, sr = sf.read(response['path'])
            assert len(audio) > 1000 and abs(audio).max() > 0.001, 'Empty/silent audio'
            output = root / f'build/{engine}-sample.wav'
            output.parent.mkdir(exist_ok=True)
            shutil.copyfile(response['path'], output)
            print(f'PASS: {len(audio) / sr:.2f}s of audio, {sr}Hz. Sample: {output}')
        else:
            assert response['chunks'] == ['Hello', 'Welcome to Murmur.']
            print('PASS: Markdown worker protocol')
    print(f'Total time including cold load/download: {time.monotonic() - start:.1f}s')
finally:
    worker.stdin.close()
    try:
        worker.wait(timeout=20)
    except subprocess.TimeoutExpired:
        worker.kill(); worker.wait()
