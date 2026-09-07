#!/bin/bash
# Repeatable, non-destructive release build. Does not install or launch the app.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:---signed}" in
  --local)
    echo "Local build: signing may be ad-hoc; permission persistence is not guaranteed."
    ;;
  --signed)
    if [ -z "${KURA_APP_SIGNING_IDENTITY:-}" ]; then
      echo "Set KURA_APP_SIGNING_IDENTITY to your stable codesigning identity, or use --local." >&2
      exit 1
    fi
    ;;
  *) echo "Usage: bash release.sh [--signed|--local]" >&2; exit 1 ;;
esac

export KURA_VERSION="${KURA_VERSION:-1.0.0}"
export KURA_BUILD_NUMBER="${KURA_BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
swift build -c release
bash check.sh
KURA_APP_OUTPUT=.build/release-app/Kura.app bash bundle.sh
codesign --verify --deep --strict .build/release-app/Kura.app
KURA_PACKAGE_APP=.build/release-app/Kura.app bash package.sh
echo "Release app: .build/release-app/Kura.app"
echo "Installer: dist/Kura-$KURA_VERSION.pkg"
echo "Existing apps, credentials, and meetings were not modified."
