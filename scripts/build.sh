#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Murmur.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/.cache/clang"
swiftc -parse-as-library -swift-version 5 -O -module-cache-path "$ROOT/.cache/clang" "$ROOT/Sources/MarkdownVoice.swift" "$ROOT/Sources/MarkdownPreview.swift" -o "$APP/Contents/MacOS/Murmur" -framework SwiftUI -framework AppKit -framework AVFoundation -framework WebKit
cp "$ROOT/backend/worker.py" "$ROOT/backend/document.py" "$APP/Contents/Resources/"
if [ -L "$APP/Contents/Resources/runtime" ]; then rm "$APP/Contents/Resources/runtime"; fi
cp "$ROOT/Assets/Murmur.icns" "$APP/Contents/Resources/Murmur.icns"
printf '%s\n' "$ROOT/.venv/bin/python" > "$APP/Contents/Resources/runtime-path.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Murmur</string>
<key>CFBundleIdentifier</key><string>local.murmur.markdownvoice</string>
<key>CFBundleName</key><string>Murmur</string>
<key>CFBundleDisplayName</key><string>Murmur</string>
<key>CFBundleIconFile</key><string>Murmur.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
rm -rf "$APP/Contents/Resources/__pycache__"
codesign --force --sign - "$APP"
touch "$APP"
echo "Built $APP"
