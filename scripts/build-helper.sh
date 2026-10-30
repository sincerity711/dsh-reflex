#!/bin/zsh
# Build ReflexKit + helper (release), bundle, sign, and install into $DSH_HOME/reflex/helper.
# usage: build-helper.sh [--no-install] [--debug]
set -euo pipefail
ROOT="${0:A:h}/.."
# One build/install at a time (concurrent runs share swift/.build and the installed app).
if [[ -z "${REFLEX_BUILD_LOCKED:-}" ]]; then
  mkdir -p "$ROOT/swift/.build"
  export REFLEX_BUILD_LOCKED=1
  exec /usr/bin/lockf -k "$ROOT/swift/.build/.reflex-build.lock" "$0" "$@"
fi
CONFIG=release
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --debug) CONFIG=debug ;;
  esac
done
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
VERSION="$(node -p "require('$ROOT/package.json').version" 2>/dev/null || echo 0.1.0)"

cd "$ROOT/swift"
swift build -c "$CONFIG" --product reflex-helper
swift build -c "$CONFIG" --product reflex-axcheck
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/swift/.build/DSH Reflex Helper.app"
"$ROOT/scripts/bundle-app.sh" "$BIN/reflex-helper" "$BIN/reflex-axcheck" "$APP" "$VERSION"

if [[ "$INSTALL" == 1 ]]; then
  DEST_DIR="$DSH_HOME/reflex/helper"
  mkdir -p "$DEST_DIR" "$DSH_HOME/reflex/programs/_axcheck"
  chmod 700 "$DSH_HOME/reflex" "$DEST_DIR"
  # Publish the complete signed bundle before stopping the old helper. DSH reconnects
  # immediately on exit; stopping first could relaunch an old or partially copied app.
  STAGING="$(mktemp -d "$DEST_DIR/.helper-update.XXXXXX")"
  ditto "$APP" "$STAGING/DSH Reflex Helper.app"
  codesign --verify --deep --strict "$STAGING/DSH Reflex Helper.app"
  INFO="$DSH_HOME/reflex/run/helper.json"
  PID=""
  if [[ -f "$INFO" ]]; then
    PID="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['pid'])" "$INFO" 2>/dev/null || true)"
  fi
  if [[ -d "$DEST_DIR/DSH Reflex Helper.app" ]]; then
    mv "$DEST_DIR/DSH Reflex Helper.app" "$STAGING/previous.app"
  fi
  if ! mv "$STAGING/DSH Reflex Helper.app" "$DEST_DIR/DSH Reflex Helper.app"; then
    [[ ! -d "$STAGING/previous.app" ]] || mv "$STAGING/previous.app" "$DEST_DIR/DSH Reflex Helper.app"
    exit 1
  fi
  if [[ -n "$PID" ]]; then
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
      kill -TERM "$PID" || true
      for _ in {1..50}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    fi
  fi
  rm -rf "$STAGING"
  # A copy outside the bundle: proves programs installed elsewhere inherit the grant too.
  cp "$BIN/reflex-axcheck" "$DSH_HOME/reflex/programs/_axcheck/reflex-axcheck"
  codesign --force --timestamp=none --sign - "$DSH_HOME/reflex/programs/_axcheck/reflex-axcheck" >/dev/null 2>&1 || true
  echo "installed $DEST_DIR/DSH Reflex Helper.app"
fi
