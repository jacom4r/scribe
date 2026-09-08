#!/usr/bin/env bash
# `swift test` wrapper for Command Line Tools-only installs, where SwiftPM
# does not add Testing.framework's search path or rpath by itself.
# Forwards all arguments, e.g. scripts/test.sh --filter DownmixTests
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
