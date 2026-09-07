#!/bin/bash
# bundle.sh — package the release binary into Kura.app and ad-hoc codesign it.
set -euo pipefail
cd "$(dirname "$0")"

BINARY=.build/release/Kura
VERSION="${KURA_VERSION:-1.0.0}"
BUILD_NUMBER="${KURA_BUILD_NUMBER:-1}"
if [ ! -f "$BINARY" ]; then
  echo "release binary not found; run: swift build -c release" >&2
  exit 1
fi

APP="${KURA_APP_OUTPUT:-Kura.app}"
case "$APP" in
  Kura.app|"Kura Updated.app"|.build/release-app/Kura.app) ;;
  *) echo "Unsupported app output path" >&2; exit 1 ;;
esac
if [ -e "$APP" ]; then
  BACKUP=".build/app-backups/Kura-$(date +%Y%m%d-%H%M%S)-$$.app"
  mkdir -p .build/app-backups
  mv "$APP" "$BACKUP"
  echo "Previous app preserved: $BACKUP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Kura"
cp Kura.icns "$APP/Contents/Resources/Kura.icns"
cp Sources/Kura/Resources/local_speech.py "$APP/Contents/Resources/local_speech.py"
cp Sources/Kura/Resources/LOCAL_SPEECH_SETUP.md "$APP/Contents/Resources/LOCAL_SPEECH_SETUP.md"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Kura</string>
	<key>CFBundleIdentifier</key>
	<string>com.karki011.kura</string>
	<key>CFBundleName</key>
	<string>Kura</string>
	<key>CFBundleDisplayName</key>
	<string>Kura</string>
	<key>CFBundleIconFile</key>
	<string>Kura</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.2</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>Kura uses the microphone for dictation and, when you enable it, to include your voice in meeting notes.</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>Kura transcribes your dictated questions using speech recognition.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Kura transcribes system audio so it can answer questions about your conversations.</string>
</dict>
</plist>
EOF

plutil -lint "$APP/Contents/Info.plist" >/dev/null
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
xattr -cr "$APP"

# Prefer a stable signing identity so macOS TCC grants (mic/speech/accessibility)
# survive rebuilds; ad-hoc signatures change every build and invalidate grants.
IDENTITY="${KURA_APP_SIGNING_IDENTITY:-}"
for candidate in "Developer ID Application" "Kura Dev" "Apple Development"; do
  if [ -n "$IDENTITY" ]; then break; fi
  # `grep` returning no match is normal; do not let `pipefail` stop an ad-hoc build.
  MATCH=$(security find-identity -v -p codesigning | grep "\"$candidate" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [ -n "$MATCH" ]; then IDENTITY="$MATCH"; break; fi
done

if [ -n "$IDENTITY" ]; then
  if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
  else
    codesign --force --deep --sign "$IDENTITY" "$APP"
  fi
  echo "signed with: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  cat <<'NOTE'
note: signed ad-hoc — macOS will re-ask permissions after each rebuild.
To make grants persist, create a self-signed "Kura Dev" codesigning certificate:
  Keychain Access → Certificate Assistant → Create a Certificate →
  Name: Kura Dev, Type: Code Signing → Create. Then rerun bundle.sh.
NOTE
fi
echo "Built and signed: $APP"
