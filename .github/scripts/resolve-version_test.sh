#!/usr/bin/env bash
# Tests for resolve-version.sh. Run: bash .github/scripts/resolve-version_test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${here}/resolve-version.sh"
pass=0
fail=0

# run REF_TYPE REF_NAME INPUT_VERSION -> sets $out and $rc
run() {
  out="$(REF_TYPE="$1" REF_NAME="$2" INPUT_VERSION="$3" LATEST_VERSION=23 \
    bash "$script" 2>/dev/null)"
  rc=$?
}

get() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }

expect() {
  local desc="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    echo "FAIL: ${desc}: want '${want}', got '${got}'"
    fail=$((fail + 1))
  fi
}

# matrix entries as "version platform runner" lines, sorted
entries() {
  get matrix | jq -r '.include[] | "\(.version) \(.platform) \(.runner)"' | sort | paste -sd';' -
}

run tag v21.0.0 ""
expect "v21.0.0 exit" 0 "$rc"
expect "v21.0.0 version" 21 "$(get version)"
expect "v21.0.0 is_latest" false "$(get is_latest)"
expect "v21.0.0 matrix" "21 linux/amd64 ubuntu-latest" "$(entries)"

run tag v23.0.8 ""
expect "v23.0.8 exit" 0 "$rc"
expect "v23.0.8 version" 23 "$(get version)"
expect "v23.0.8 is_latest" true "$(get is_latest)"
expect "v23.0.8 matrix" "23 linux/amd64 ubuntu-latest;23 linux/arm64 ubuntu-24.04-arm" "$(entries)"

run branch master ""
expect "master exit" 0 "$rc"
expect "master version" "" "$(get version)"
expect "master is_latest" false "$(get is_latest)"
expect "master matrix" "21 linux/amd64 ubuntu-latest;23 linux/amd64 ubuntu-latest;23 linux/arm64 ubuntu-24.04-arm" "$(entries)"

run branch master 21
expect "input 21 exit" 0 "$rc"
expect "input 21 version" 21 "$(get version)"
expect "input 21 matrix" "21 linux/amd64 ubuntu-latest" "$(entries)"

run tag v22.0.0 ""
expect "v22.0.0 rejected" 1 "$rc"
run branch master 22
expect "input 22 rejected" 1 "$rc"
run branch master "21;rm -rf /"
expect "input with shell metachars rejected" 1 "$rc"

echo "resolve-version_test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
