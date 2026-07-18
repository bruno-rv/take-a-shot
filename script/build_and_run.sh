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
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
INSTALLED_APP="/Applications/$APP_NAME.app"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

VERIFY_PID=""
VERIFY_PROFILE_FILE=""

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

install_app() {
  rm -rf "$INSTALLED_APP"
  ditto "$APP_BUNDLE" "$INSTALLED_APP"
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
  /usr/bin/open -n "$INSTALLED_APP"
}

cleanup_verification_process() {
  if [[ -n "$VERIFY_PID" ]] && kill -0 "$VERIFY_PID" >/dev/null 2>&1; then
    kill "$VERIFY_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$VERIFY_PID" ]]; then
    wait "$VERIFY_PID" 2>/dev/null || true
    VERIFY_PID=""
  fi
  if [[ -n "$VERIFY_PROFILE_FILE" ]]; then
    rm -f "$VERIFY_PROFILE_FILE"
    VERIFY_PROFILE_FILE=""
  fi
}

launch_and_verify_app() {
  VERIFY_PROFILE_FILE="${TMPDIR:-/tmp}/take-a-shot-verify-$$.profraw"
  LLVM_PROFILE_FILE="$VERIFY_PROFILE_FILE" "$APP_EXECUTABLE" >/dev/null 2>&1 &
  VERIFY_PID=$!
  trap cleanup_verification_process EXIT
  trap 'exit 130' HUP INT TERM

  local stable_checks=0
  local attempt
  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if kill -0 "$VERIFY_PID" >/dev/null 2>&1; then
      stable_checks=$((stable_checks + 1))
      if ((stable_checks == 5)); then
        cleanup_verification_process
        trap - EXIT HUP INT TERM
        return 0
      fi
    else
      echo "$APP_NAME exited before verification completed" >&2
      return 1
    fi
    sleep 0.1
  done

  echo "$APP_NAME did not remain live during verification" >&2
  return 1
}

if [[ "$MODE" != "--verify" && "$MODE" != "verify" ]]; then
  stop_app
fi
build_app
install_app

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
    launch_and_verify_app
    ;;
  *)
    usage
    exit 2
    ;;
esac
