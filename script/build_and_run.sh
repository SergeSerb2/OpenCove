#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
if [ "$#" -gt 1 ]; then
  echo "Expected one mode. See docs/building.md." >&2
  exit 2
fi
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify|--control|--build|--release) ;;
  *) echo "usage: $0 [--build|--release|--verify|--control|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
cd "$ROOT_DIR"
CONFIGURATION="debug"
VARIANT="development"
DEFAULT_OUTPUT="$ROOT_DIR/dist"
if [ "$MODE" = "--release" ]; then
  CONFIGURATION="release"
  VARIANT="release"
  DEFAULT_OUTPUT="$ROOT_DIR/dist/release"
fi
# This wrapper is for local ad-hoc use. Developer ID is an explicit packaging
# command, not an ambient environment change to a normal development build.
APP_BUNDLE="${OPENCOVE_OUTPUT_DIR:-$DEFAULT_OUTPUT}/OpenCove.app"
APP_BUNDLE="$(python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]).expanduser(); print(p.parent.resolve()/p.name)' "$APP_BUNDLE")"
BUILD_ARGS=(build --configuration "$CONFIGURATION" --variant "$VARIANT"
  --output "$APP_BUNDLE" --arch "${OPENCOVE_ARCH:-$(uname -m)}" --signing adhoc --replace)
if [ -n "${OPENCOVE_SCRATCH_PATH:-}" ]; then
  BUILD_ARGS+=(--scratch-path "$OPENCOVE_SCRATCH_PATH")
fi
python3 "$ROOT_DIR/script/package_release.py" "${BUILD_ARGS[@]}"
if [ "$MODE" = "--build" ] || [ "$MODE" = "--release" ]; then exit 0; fi

# Packaging refuses to replace an app that is running. Quit that instance or
# choose a separate OPENCOVE_OUTPUT_DIR; never kill a process by name here.
OPENCOVE_DATA_DIR="$(python3 "$ROOT_DIR/script/verify_control.py" --prepare-data-dir "${OPENCOVE_DATA_DIR:-$ROOT_DIR/.local/runtime}")"
export OPENCOVE_DATA_DIR
BUILD_VERSION="$(python3 -c 'import json; from pathlib import Path; print(json.loads(Path("version.json").read_text())["build"])')"
case "$MODE" in
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/OpenCove" ;;
  --control) /usr/bin/open -n "$APP_BUNDLE" --env "OPENCOVE_DATA_DIR=$OPENCOVE_DATA_DIR" --args --control-port 48765 --no-onboarding ;;
  *) /usr/bin/open -n "$APP_BUNDLE" --env "OPENCOVE_DATA_DIR=$OPENCOVE_DATA_DIR" ;;
esac
case "$MODE" in
  --logs) /usr/bin/log stream --info --style compact --predicate 'process == "OpenCove"' ;;
  --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "org.opencove.OpenCove"' ;;
  --control) python3 "$ROOT_DIR/script/verify_control.py" "$OPENCOVE_DATA_DIR" "$BUILD_VERSION" "$APP_BUNDLE" ;;
  --verify)
    sleep 1
    PROCESS_PATTERN="$(python3 -c 'import re,sys; print("^"+re.escape(sys.argv[1])+"( |$)")' "$APP_BUNDLE/Contents/MacOS/OpenCove")"
    pgrep -f "$PROCESS_PATTERN" >/dev/null
    echo "OpenCove process is running; feature verification is separate."
    ;;
esac
