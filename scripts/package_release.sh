#!/bin/bash
# Build a relocatable Apple Silicon app without Developer ID or model downloads.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export UV_CACHE_DIR="$ROOT/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$ROOT/.cache/python"
uv python install 3.11.17
PYTHON="$(uv python find --managed-python 3.11.17)"
APP="$ROOT/build/AudibleInk.app"
RUNTIME="$APP/Contents/Resources/python"
# Start from an allowlisted build, never an existing app or a user profile.
rm -rf "$APP"
mkdir -p "$APP/Contents/Resources"
cp -R "$(dirname "$(dirname "$PYTHON")")" "$RUNTIME"
uv pip install --python "$RUNTIME/bin/python3.11" --target "$RUNTIME/lib/python3.11/site-packages" -r backend/requirements/base.lock
printf '%s\n' '{"version": 1, "dependencies": "on-first-use"}' > "$RUNTIME/audibleink-runtime.json"
# Drop bytecode and development payloads, retaining package data and licenses.
find "$RUNTIME" -type d -name __pycache__ -prune -exec rm -rf {} +
rm -rf "$RUNTIME/lib/python3.11/test" "$RUNTIME/lib/python3.11/idlelib"
"$ROOT/scripts/build.sh"
# Ad-hoc signatures support local execution; this is not Developer ID signing.
"$RUNTIME/bin/python3.11" - "$APP" <<'PY'
from pathlib import Path
import subprocess, sys
app = Path(sys.argv[1])
magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as stream:
        native = stream.read(4) in magic
    if native:
        subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True, capture_output=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
PY
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p build/release
ARCHIVE="$ROOT/build/release/AudibleInk-$VERSION-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
STAGE="$ROOT/build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -srcfolder "$STAGE" -volname AudibleInk -format UDZO -ov "$ROOT/build/release/AudibleInk-$VERSION-macos-arm64.dmg"
(cd build/release && shasum -a 256 "AudibleInk-$VERSION-macos-arm64.zip" "AudibleInk-$VERSION-macos-arm64.dmg" > SHA256SUMS.txt)
echo "Release archive: $ARCHIVE"
