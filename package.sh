#!/bin/bash
# package.sh — build a macOS Installer package that installs Kura into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${KURA_VERSION:-1.0.0}"
APP="${KURA_PACKAGE_APP:-.build/release-app/Kura.app}"
DIST="dist"
PKG="$DIST/Kura-$VERSION.pkg"

if [ ! -d "$APP" ]; then
  echo "Release app not found; run: bash release.sh --local" >&2
  exit 1
fi

mkdir -p "$DIST"
if [ -e "$PKG" ]; then
  mkdir -p "$DIST/backups"
  mv "$PKG" "$DIST/backups/Kura-$VERSION-$(date +%Y%m%d-%H%M%S)-$$.pkg"
fi

APP_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")

INSTALLER_IDENTITY="${KURA_INSTALLER_SIGNING_IDENTITY:-}"
if [ -z "$INSTALLER_IDENTITY" ]; then
  INSTALLER_IDENTITY=$(security find-identity -v | grep '"Developer ID Installer:' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
fi

# Stage the app in a root dir so pkgbuild can attach a component plist.
# BundleIsRelocatable=false stops PackageKit from "relocating" the install
# to any other Kura.app copy it finds on disk (e.g. dev builds), which
# otherwise leaves /Applications without the app.
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ROOT="$STAGING/root"
mkdir -p "$ROOT"
ditto "$APP" "$ROOT/$(basename "$APP")"

COMPONENTS_PLIST="$STAGING/components.plist"
pkgbuild --analyze --root "$ROOT" "$COMPONENTS_PLIST"
# Apply to every analyzed bundle entry, not just the first, so nested
# bundles (helpers, frameworks, XPC services) stay non-relocatable too.
i=0
while /usr/libexec/PlistBuddy -c "Print :$i:BundleIsRelocatable" "$COMPONENTS_PLIST" >/dev/null 2>&1; do
  /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$COMPONENTS_PLIST"
  i=$((i + 1))
done

if [ -n "$INSTALLER_IDENTITY" ]; then
  pkgbuild \
    --root "$ROOT" \
    --component-plist "$COMPONENTS_PLIST" \
    --identifier "$APP_ID" \
    --version "$VERSION" \
    --install-location /Applications \
    --sign "$INSTALLER_IDENTITY" \
    "$PKG"
  echo "signed installer with: $INSTALLER_IDENTITY"
else
  pkgbuild \
    --root "$ROOT" \
    --component-plist "$COMPONENTS_PLIST" \
    --identifier "$APP_ID" \
    --version "$VERSION" \
    --install-location /Applications \
    "$PKG"
  echo "note: built an unsigned installer; distribution requires a Developer ID Installer certificate."
fi

if [ -n "${KURA_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$KURA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

echo "Built installer: $PKG"
