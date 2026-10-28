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
uv --cache-dir "$ROOT/.cache/uv" pip sync --python "$ROOT/.venv/bin/python" "$ROOT/requirements.lock"
"$ROOT/scripts/build.sh"
echo 'Ready. Open build/AudibleInk.app to listen.'
