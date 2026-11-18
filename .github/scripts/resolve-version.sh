#!/usr/bin/env bash
# Decide which Oracle versions and platforms a CI run builds. Prints
# GITHUB_OUTPUT lines (version=, is_latest=, matrix=) on stdout.
#
# Env: EVENT_NAME, REF_TYPE, REF_NAME (github.event_name / ref_type / ref_name),
# INPUT_VERSION (workflow_dispatch input, may be empty), LATEST_VERSION.
#
#   INPUT_VERSION set -> that version only
#   tag push          -> the tag's major (v21.0.0 -> 21); the only case that publishes
#   anything else     -> every known version (PRs, branch pushes, and a manual run
#                        with a blank input, even one started on a tag ref)
#
# version= is empty when every version is built. This is the one place the
# version -> platforms table lives; the Dockerfile has a matching base-NN stage
# per version. Tested by resolve-version_test.sh.
set -euo pipefail

known_versions=(21 23)

# Matrix entries for one version, one JSON object per line.
entries_for() {
  case "$1" in
    23)
      jq -nc --arg v 23 '{version: $v, platform: "linux/amd64", runner: "ubuntu-latest"}'
      jq -nc --arg v 23 '{version: $v, platform: "linux/arm64", runner: "ubuntu-24.04-arm"}'
      ;;
    21)
      # gvenzl/oracle-xe:21 is amd64-only, and Oracle doesn't run under QEMU.
      jq -nc --arg v 21 '{version: $v, platform: "linux/amd64", runner: "ubuntu-latest"}'
      ;;
  esac
}

is_known() {
  local k
  for k in "${known_versions[@]}"; do
    [ "$1" = "$k" ] && return 0
  done
  return 1
}

version=""
if [ -n "${INPUT_VERSION:-}" ]; then
  version="$INPUT_VERSION"
elif [ "${EVENT_NAME:?EVENT_NAME is required}" = "push" ] && [ "${REF_TYPE:-}" = "tag" ]; then
  version="${REF_NAME#v}"   # v21.0.0 -> 21.0.0
  version="${version%%.*}"  # 21.0.0  -> 21
fi

if [ -n "$version" ]; then
  case "$version" in
    *[!0-9]*)
      echo "::error::invalid Oracle version: '${version}'" >&2
      exit 1
      ;;
  esac
  if ! is_known "$version"; then
    echo "::error::unknown Oracle version '${version}' (known: ${known_versions[*]})" >&2
    exit 1
  fi
  build=("$version")
else
  build=("${known_versions[@]}")
fi

is_latest=false
if [ -n "$version" ] && [ "$version" = "${LATEST_VERSION:?LATEST_VERSION is required}" ]; then
  is_latest=true
fi

matrix="$(for v in "${build[@]}"; do entries_for "$v"; done | jq -sc '{include: .}')"

echo "version=${version}"
echo "is_latest=${is_latest}"
echo "matrix=${matrix}"
