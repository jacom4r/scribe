#!/usr/bin/env bash
# Builds the Scribe executable, wraps it in build/Scribe.app, signs it, and
# launches it. Usage: scripts/bundle.sh [debug|release] [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
IDENTITY="${SCRIBE_SIGN_IDENTITY:-Scribe Dev}"
APP="build/Scribe.app"
BUNDLE_ID="com.jacobmarchionda.scribe"

swift build -c "$CONFIG" --product Scribe
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Scribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "warning: no '$IDENTITY' identity found; ad-hoc signing." >&2
  echo "         Audio permission will re-prompt after every rebuild. Run scripts/make-dev-cert.sh." >&2
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

echo "Built $APP"
if [[ "${2:-}" != "--no-open" ]]; then
  pkill -x Scribe 2>/dev/null || true
  open "$APP"
fi
