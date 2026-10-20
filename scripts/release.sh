#!/usr/bin/env bash
# Builds a release Scribe.app, zips it, and publishes it as a GitHub release
# tagged v<CFBundleShortVersionString>. Bump the version in
# Resources/Info.plist first. Usage: scripts/release.sh [--draft]
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SCRIBE_SIGN_IDENTITY:-Scribe Dev}"
# Releases must use the stable identity: macOS ties a user's mic and audio
# permission grants to it, so an ad-hoc build would re-prompt after updates.
if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "error: no '$IDENTITY' signing identity. Run scripts/make-dev-cert.sh." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: uncommitted changes; commit before releasing." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
ZIP="build/Scribe-$VERSION.zip"

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: release $TAG already exists; bump CFBundleShortVersionString." >&2
  exit 1
fi

scripts/bundle.sh release --no-open
codesign --verify --strict build/Scribe.app
# ditto keeps the bundle's signature and metadata intact; plain zip can break it.
ditto -c -k --keepParent build/Scribe.app "$ZIP"

git push origin HEAD
gh release create "$TAG" "$ZIP" --target "$(git rev-parse HEAD)" --title "Scribe $VERSION" \
  --notes "See the README's Install section for first-launch steps." "$@"
