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

INSTALLER_IDENTITY="${KURA_INSTALLER_SIGNING_IDENTITY:-}"
if [ -z "$INSTALLER_IDENTITY" ]; then
  INSTALLER_IDENTITY=$(security find-identity -v | grep '"Developer ID Installer:' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
fi

if [ -n "$INSTALLER_IDENTITY" ]; then
  productbuild \
    --sign "$INSTALLER_IDENTITY" \
    --component "$APP" /Applications \
    "$PKG"
  echo "signed installer with: $INSTALLER_IDENTITY"
else
  productbuild --component "$APP" /Applications "$PKG"
  echo "note: built an unsigned installer; distribution requires a Developer ID Installer certificate."
fi

if [ -n "${KURA_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$PKG" --keychain-profile "$KURA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

echo "Built installer: $PKG"
