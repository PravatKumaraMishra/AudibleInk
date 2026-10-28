#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AudibleInk.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/.cache/clang"
swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$ROOT/.cache/clang" "$ROOT/Sources/MarkdownVoice.swift" "$ROOT/Sources/MarkdownPreview.swift" -o "$APP/Contents/MacOS/AudibleInk" -framework SwiftUI -framework AppKit -framework AVFoundation -framework WebKit -framework PDFKit
cp "$ROOT/backend/worker.py" "$ROOT/backend/document.py" "$ROOT/backend/dependencies.py" "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/requirements"
cp -R "$ROOT/backend/requirements" "$APP/Contents/Resources/requirements"
if [ -L "$APP/Contents/Resources/runtime" ]; then rm "$APP/Contents/Resources/runtime"; fi
cp "$ROOT/Assets/AudibleInk.icns" "$APP/Contents/Resources/AudibleInk.icns"
if [ -x "$APP/Contents/Resources/python/bin/python3.11" ]; then
  rm -f "$APP/Contents/Resources/runtime-path.txt"
else
  printf '%s\n' "$ROOT/.venv/bin/python" > "$APP/Contents/Resources/runtime-path.txt"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AudibleInk</string>
<key>CFBundleIdentifier</key><string>local.audibleink.markdownvoice</string>
<key>CFBundleName</key><string>AudibleInk</string>
<key>CFBundleDisplayName</key><string>AudibleInk</string>
<key>CFBundleIconFile</key><string>AudibleInk.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
rm -rf "$APP/Contents/Resources/__pycache__"
codesign --force --sign - "$APP"
touch "$APP"
echo "Built $APP"
