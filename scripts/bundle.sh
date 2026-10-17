#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Boty.app"
BIN="$ROOT/.build/release/Boty"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Boty"
cp "$ROOT/Resources/Boty.icns" "$APP/Contents/Resources/Boty.icns"
# Recursos SwiftPM (si los hubiera).
for bundle in "$ROOT"/.build/release/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>es</string>
    <key>CFBundleExecutable</key>
    <string>Boty</string>
    <key>CFBundleIdentifier</key>
    <string>com.boty.app</string>
    <key>CFBundleName</key>
    <string>Boty</string>
    <key>CFBundleDisplayName</key>
    <string>Boty</string>
    <key>CFBundleIconFile</key>
    <string>Boty</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Boty usa el micrófono para el dictado por voz: transcribe lo que dices al cajón de texto.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Boty usa el reconocimiento de voz para transcribir tu dictado al cajón de texto.</string>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "OK: $APP"
