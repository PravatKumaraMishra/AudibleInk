#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if ! command -v uv >/dev/null; then
  echo 'Install uv first: brew install uv'; exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
  echo 'Kokoro MLX requires an Apple Silicon Mac. Run this terminal without Rosetta.'; exit 1
fi
uv --cache-dir "$ROOT/.cache/uv" venv --python 3.11 "$ROOT/.venv"
uv --cache-dir "$ROOT/.cache/uv" pip install --python "$ROOT/.venv/bin/python" -r "$ROOT/requirements.txt"
# Misaki uses this English pronunciation pipeline. Install up front for offline use.
uv --cache-dir "$ROOT/.cache/uv" pip install --python "$ROOT/.venv/bin/python" 'https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl'
"$ROOT/scripts/build.sh"
echo 'Ready. Open build/Murmur.app to listen.'
