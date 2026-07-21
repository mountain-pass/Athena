#!/usr/bin/env bash
# Build and launch Athena without touching Xcode.
#
#   ./Scripts/run.sh          build + run (regenerates project only if needed)
#   ./Scripts/run.sh --gen    force project regeneration first
#   ./Scripts/run.sh --watch  rebuild + relaunch automatically on file changes
#
# Requires: xcodegen (brew install xcodegen)
# Optional: fswatch for --watch  (brew install fswatch)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=Athena
DERIVED=.build/xcode

SOURCE_MANIFEST=.build/sources.sha

# Fingerprint of the source file *set* (names, not contents). XcodeGen globs
# the Athena/ directory, so the project only needs regenerating when files are
# added, removed or renamed — not on every edit.
source_fingerprint() {
  find "$APP_NAME" -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' \
    | sort | shasum | cut -d' ' -f1
}

generate_if_needed() {
  local fingerprint
  fingerprint="$(source_fingerprint)"

  # NOTE: checking only `project.yml -nt project` is not enough — that misses
  # newly added source files, which then fail to compile with a baffling
  # "Cannot find X in scope" even though the file is right there on disk.
  if [ ! -d "$APP_NAME.xcodeproj" ] \
     || [ project.yml -nt "$APP_NAME.xcodeproj" ] \
     || [ ! -f "$SOURCE_MANIFEST" ] \
     || [ "$fingerprint" != "$(cat "$SOURCE_MANIFEST")" ]; then
    echo "→ regenerating project…"
    xcodegen
    mkdir -p "$(dirname "$SOURCE_MANIFEST")"
    printf '%s' "$fingerprint" > "$SOURCE_MANIFEST"
  fi
}

build_and_run() {
  generate_if_needed
  echo "→ building…"
  xcodebuild build \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED" \
    -quiet
  APP_PATH="$DERIVED/Build/Products/Debug/$APP_NAME.app"
  echo "→ relaunching…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$APP_PATH"
}

case "${1:-}" in
  --gen)
    xcodegen && build_and_run
    ;;
  --watch)
    command -v fswatch >/dev/null || { echo "brew install fswatch first"; exit 1; }
    build_and_run
    echo "→ watching Athena/ for changes (Ctrl-C to stop)…"
    fswatch -o -e ".*" -i "\\.swift$" Athena | while read -r _; do
      echo; echo "── change detected ──"
      build_and_run || echo "build failed — fix and save again"
    done
    ;;
  *)
    build_and_run
    ;;
esac
