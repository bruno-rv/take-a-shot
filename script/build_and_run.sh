#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="TakeAShot"
BUNDLE_ID="com.bruno.takeashot"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/TakeAShot.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
VERIFY_DERIVED_DATA="${VERIFY_DERIVED_DATA:-$ROOT_DIR/.build/VerifyDerivedData}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    build
}

test_app() {
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$VERIFY_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    test_app
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    usage
    exit 2
    ;;
esac
