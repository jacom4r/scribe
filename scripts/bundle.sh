#!/usr/bin/env bash
# Builds the Scribe executable, wraps it in build/Scribe.app, signs it, and
# launches it. Usage: scripts/bundle.sh [debug|release] [--no-open]
# Both arguments are optional and order-independent.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
OPEN=1
for a in "$@"; do
  case "$a" in
    debug|release) CONFIG="$a" ;;
    --no-open) OPEN=0 ;;
    *) echo "usage: $0 [debug|release] [--no-open]" >&2; exit 2 ;;
  esac
done
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
if [[ "$OPEN" == 1 ]]; then
  # Quit gracefully so a running instance can finalize an in-progress
  # recording (AppDelegate.applicationShouldTerminate); SIGTERM would not.
  if pgrep -x Scribe >/dev/null; then
    osascript -e 'quit app "Scribe"' 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do pgrep -x Scribe >/dev/null || break; sleep 0.5; done
    pkill -x Scribe 2>/dev/null || true
  fi
  open "$APP"
fi
