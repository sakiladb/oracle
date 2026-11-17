#!/usr/bin/env bash
# Smoke-test a built sakiladb/oracle image: run it, wait for `healthy`, then
# query the SAKILA PDB as the sakila user and check the Sakila contract.
#
#   ./smoke-test.sh IMAGE                  check IMAGE (exit 0 pass, 1 fail)
#   ./smoke-test.sh --update-hashes IMAGE  rewrite testdata/view-hashes.txt
#
# Checks: 16 tables + 7 views, key row counts, the staff.picture BLOB, and that
# each view's full output hashes to the committed testdata/view-hashes.txt
# (shared by every Oracle version, so 21c and 23ai must return identical view
# output). SMOKE_TIMEOUT (default 300) bounds the wait for `healthy`.
# SMOKE_EXPECT_MAJOR (e.g. 21), if set, also checks the running Oracle major.
#
# Runs its own uniquely named container with no published ports, and removes
# it on exit. Used by CI for every image, and by `make test`.

set -Eeuo pipefail

update=0
if [ "${1:-}" = "--update-hashes" ]; then
  update=1
  shift
fi
image="${1:?usage: smoke-test.sh [--update-hashes] IMAGE}"
timeout="${SMOKE_TIMEOUT:-300}"
here="$(cd "$(dirname "$0")" && pwd)"
hashes="${here}/testdata/view-hashes.txt"
name="sakila-smoke-$$-${RANDOM}"
views=(actor_info customer_list film_list nicer_but_slower_film_list
       sales_by_film_category sales_by_store staff_list)

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

diagnostics() {
  echo "--- container health:"
  docker inspect -f '{{json .State.Health}}' "$name" 2>/dev/null || true
  echo "--- container logs (last 200 lines):"
  docker logs --tail 200 "$name" 2>&1 || true
}

die() {
  echo "smoke-test: FAIL: $*" >&2
  diagnostics >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# Run SQL*Plus inside the container as sakila, over the listener.
sakila_sql() {
  docker exec -i "$name" sqlplus -L -S "sakila/p_ssW0rd@//localhost:1521/SAKILA"
}

# Print the single value a query returns, whitespace stripped.
scalar() {
  printf 'WHENEVER SQLERROR EXIT FAILURE\nSET PAGESIZE 0 FEEDBACK OFF HEADING OFF\n%s\nEXIT\n' "$1" \
    | sakila_sql | tr -d '[:space:]'
}

# Hash a view's full output. The SQL*Plus settings and the C-locale sort are
# part of the fixture: change them and every hash changes.
view_hash() {
  printf '%s\n' \
    'WHENEVER SQLERROR EXIT FAILURE' \
    "SET PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON TRIMOUT ON FEEDBACK OFF HEADING OFF COLSEP '|' LONG 100000" \
    "SELECT * FROM $1;" \
    'EXIT' \
    | sakila_sql | LC_ALL=C sort | sha256
}

failures=0
check() {
  local label="$1" want="$2" got
  got="$(scalar "$3")" || die "query failed for ${label}: ${got}"
  if [ "$got" = "$want" ]; then
    echo "ok    ${label} = ${got}"
  else
    echo "FAIL  ${label}: want ${want}, got ${got}"
    failures=$((failures + 1))
  fi
}

echo "smoke-test: starting ${image}"
docker run -d --name "$name" "$image" >/dev/null || die "could not start ${image}"

start=$SECONDS
while :; do
  state="$(docker inspect -f '{{.State.Status}}' "$name")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")"
  [ "$state" = "running" ] || die "container is ${state}, not running"
  case "$health" in
    healthy) break ;;
    unhealthy) die "container reported unhealthy" ;;
    "") die "image has no HEALTHCHECK" ;;
  esac
  if (( SECONDS - start >= timeout )); then
    die "not healthy after ${timeout}s (status: ${health})"
  fi
  sleep 2
done
echo "smoke-test: healthy after $((SECONDS - start))s"

# Every other check is version-agnostic, so without this a build that silently
# ignored ORACLE_MAJOR (and built the default 23) would pass as "21".
if [ -n "${SMOKE_EXPECT_MAJOR:-}" ]; then
  check oracle_major "$SMOKE_EXPECT_MAJOR" \
    "SELECT REGEXP_SUBSTR(version, '^[0-9]+') FROM product_component_version WHERE ROWNUM = 1;"
fi
check tables              16    "SELECT COUNT(*) FROM user_tables;"
check views               7     "SELECT COUNT(*) FROM user_views;"
check actor               200   "SELECT COUNT(*) FROM actor;"
check film                1000  "SELECT COUNT(*) FROM film;"
check rental              16044 "SELECT COUNT(*) FROM rental;"
check payment             16049 "SELECT COUNT(*) FROM payment;"
check staff_1_picture_len 36365 "SELECT DBMS_LOB.GETLENGTH(picture) FROM staff WHERE staff_id = 1;"
check staff_2_picture_null 1    "SELECT COUNT(*) FROM staff WHERE staff_id = 2 AND picture IS NULL;"

if (( update )); then
  mkdir -p "$(dirname "$hashes")"
  out=""
  for v in "${views[@]}"; do
    h="$(view_hash "$v")" || die "query failed for view ${v}"
    out+="${v} ${h}"$'\n'
  done
  printf '%s' "$out" > "$hashes"
  echo "smoke-test: wrote ${hashes}"
else
  [ -f "$hashes" ] || die "missing ${hashes} (generate it with --update-hashes)"
  for v in "${views[@]}"; do
    want="$(awk -v v="$v" '$1 == v { print $2 }' "$hashes")"
    got="$(view_hash "$v")" || die "query failed for view ${v}"
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
      echo "ok    view ${v}"
    else
      echo "FAIL  view ${v}: want ${want:-<missing>}, got ${got}"
      failures=$((failures + 1))
    fi
  done
fi

if (( failures )); then
  die "${failures} check(s) failed"
fi
echo "smoke-test: PASS (${image})"
