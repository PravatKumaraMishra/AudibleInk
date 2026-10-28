"""Audit the clean minimal bundle before publishing it."""
from pathlib import Path
import json
import subprocess
import sys

app = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/AudibleInk.app').resolve()
resources = app / 'Contents/Resources'
expected = {'AudibleInk.icns', 'worker.py', 'document.py', 'dependencies.py', 'requirements', 'python'}
assert {p.name for p in resources.iterdir()} == expected, 'Unexpected bundled resource'
for path in app.rglob('*'):
    assert path.suffix.lower() not in {'.wav', '.mp3', '.m4a', '.flac', '.safetensors', '.pt', '.docx', '.pdf', '.rtf', '.plist'} or path == app / 'Contents/Info.plist', f'Unexpected user/model asset: {path}'
    assert path.name not in {'token', 'recentDocuments', 'audio', 'huggingface', '.DS_Store'}, f'Unexpected user state: {path}'
marker = json.loads((resources / 'python/audibleink-runtime.json').read_text())
assert marker['dependencies'] == 'on-first-use'
python = resources / 'python/bin/python3.11'
subprocess.run([str(python), '-I', '-B', '-c', '''
import importlib.util
from markdown_it import MarkdownIt
assert '<h1>Preview</h1>' in MarkdownIt().render('# Preview')
for module in ('mlx', 'mlx_audio', 'numpy', 'scipy', 'spacy', 'transformers', 'indic_f5_mlx', 'torch'):
    assert importlib.util.find_spec(module) is None, module
print('PASS: minimal preview runtime; no engine libraries bundled')
'''], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('PASS: only allowlisted resources; no recordings, speech weights, tokens, or personal preferences')
