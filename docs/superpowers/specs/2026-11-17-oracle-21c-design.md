# Design: publish Oracle 21c (XE) alongside 23ai

Issue: [#11](https://github.com/sakiladb/oracle/issues/11). Spike: branch `spike/21c-xe`, CI run
`44187864553` (21 and 23 both green on amd64).

## Intent

Publish `sakiladb/oracle:21`, built on Oracle Database 21c Express Edition, from the same `master`
and the same tag-driven release as the existing `:23` image. The consumer is
[`sq`](https://github.com/neilotoole/sq), whose CI tests its Oracle driver against `sakiladb/oracle`.
Most Oracle users run 19c, which has no free edition; 21c is the closest version that can be
published, and like 19c it lacks the 23ai features that most often cause version differences. A 21c
image is a stand-in for 19c, not a target in its own right.

## Goals

- `sakiladb/oracle:21` on Docker Hub and GHCR, `linux/amd64` only, cosign-signed, with provenance
  and SBOM attestations, released by pushing a `v21.0.x` tag.
- The 21 image exposes the same Sakila contract as 23: 16 tables + 7 views, same row counts,
  `staff.picture` intact, view output identical (the spike's view hashes matched exactly).
- `:latest` stays on 23 no matter what order tags are pushed in.
- One set of SQL files serves both versions.
- A CI smoke test that runs the built image and queries it, for every version, on every build,
  including a check that view output matches a committed baseline.

## Non-goals

- 19c (no free edition), 18c, or any other version.
- `arm64` for 21 (`gvenzl/oracle-xe:21` is amd64-only, and Oracle does not run under QEMU).
- Changing the 23 image's contents. Its data-file format changes (below), but the loaded data must
  be identical.

## Anti-goals

- A 21 release that silently moves `:latest`, or overwrites `:23`.
- A separate, hand-maintained SQL fork for 21c that drifts from 23.
- A PR that is green on 23 but would break the 21 build at release time.

## Constraints (established by the spike)

1. **21c has no multi-row `INSERT … VALUES (…),(…)`** (23ai-only syntax; 21c raises `ORA-00933`).
2. **21c's SQL\*Plus rejects script lines over 3000 characters** (`SP2-0341`); 23's limit is 4999.
   The current BLOB reassembly emits ~4050-char `DBMS_LOB.WRITEAPPEND` lines.
3. **`SP2-` errors are not caught by `WHENEVER SQLERROR EXIT`**: the failing statement is skipped and
   the script continues. The existing post-load tripwires are what catch this; keep them.
4. **XE's default PDB is `XEPDB1`** (Free's is `FREEPDB1`), its data directory marker is
   `dbconfig/XE`, and its `healthcheck.sh` takes the PDB as `$1` exactly like Free's.
5. **`ORACLE_DATABASE` works on XE 21c** (creates the `SAKILA` PDB and app user).
6. **BuildKit caps a step's log at 2 MiB.** Fixed separately (see Sequencing).
7. The existing release topology must hold: one native runner per arch, push by digest, a merge job
   that assembles the manifest list, signs, attests and self-verifies.

## Approaches

**Where each version's pinned base image lives** (the main decision):

- **A. Stage aliases in the Dockerfile — chosen.** One literal `FROM <image>:<exact tag> AS base-NN`
  per version, then `FROM base-${ORACLE_MAJOR}`. Pins stay literal, so Dependabot's Docker
  ecosystem can still read and bump them; a local build needs only `--build-arg ORACLE_MAJOR=21`;
  BuildKit pulls only the stage it uses. Proven on both versions in the spike.
- **B. Workflow maps version to a full image ref, passed as a build arg** (as `sakiladb/sqlserver`
  does). Simpler Dockerfile, but the pins move into YAML that Dependabot's Docker updates don't
  read, and local builds need the full ref. Rejected.

The maintainer chose A.

**How the SQL serves both versions:** one data file in a form both accept (chosen), versus a
per-version data file. One file avoids drift (an anti-goal) and the spike showed it costs nothing:
the 23 build got *faster* (509s → ~150s) with one `INSERT` per row, and its view hashes were
unchanged.

## Decided design

### Dockerfile

- Replace `ARG ORACLE_VERSION=23.26.2` with `ARG ORACLE_MAJOR=23` (default: newest, so a plain local
  `docker build .` still produces 23).
- Two alias stages, before `builder`:
  `FROM gvenzl/oracle-free:23.26.2-slim-faststart AS base-23` and
  `FROM gvenzl/oracle-xe:21.3.0-slim-faststart AS base-21`.
- `builder` and the final stage both `FROM base-${ORACLE_MAJOR}`.
- `HEALTHCHECK` unchanged (`healthcheck.sh SAKILA` works on both).
- Update comments that say `FREEPDB1` / `dbconfig/FREE` to cover both.

### `init-as-sakila.sh`

- Drop the default PDB by detection: every PDB in `v$pdbs` other than `PDB$SEED` and `SAKILA`.
  Proven in the spike on both versions.

### `convert_data.py` (regenerates `2-oracle-sakila-data.sql`)

- Emit **one `INSERT INTO t VALUES (…);` per row** instead of passing through MySQL's multi-row
  lists. The input has exactly one row per line (verified), so this is a line-wise rewrite of the
  row lines, applied after the existing per-table fixes (`staff.picture` → `NULL`, address geometry
  strip). Expected output: 46,273 `INSERT`s.
- Drop `SET SQLBLANKLINES ON` only if nothing needs it any more (it existed for blank lines inside
  long multi-row lists).
- BLOB chunk size: **2000 hex chars (1000 bytes) per `WRITEAPPEND`** (37 statements), keeping each
  line ~2050 chars, under 21c's 3000. Update the docstring's line-limit rationale.
- Add a generator-side guard: `fail()` if any emitted line exceeds 2999 chars, so a future change
  can't reintroduce `SP2-0341` silently.
- Header comment: "for Oracle 21c and 23ai".
- Regenerate and commit `2-oracle-sakila-data.sql`. On `master` today the generator reproduces the
  committed file byte for byte. The new output should match the spike's file (46,273 `INSERT`s, 37
  `WRITEAPPEND`s, longest line 2051 chars) apart from the header comment.

### Workflow (`docker-publish.yml`)

- Add `env.LATEST_VERSION: "23"`.
- **New `setup` job** that decides the version and its platform matrix, and outputs both:
  - version: `workflow_dispatch` input `oracle_version` if set; else, on a tag, the tag's major
    (`v21.0.0` → `21`); else `LATEST_VERSION`. Validate: digits only, and one of the known versions
    (`21`, `23`), else fail.
  - matrix: `23` → amd64 on `ubuntu-latest` + arm64 on `ubuntu-24.04-arm`; `21` → amd64 only.
    Emitted as JSON and consumed by `build` via `fromJSON`.
- `build` job: `needs: setup`; passes `ORACLE_MAJOR` as a build arg; GHA cache scope includes the
  version (e.g. `23-linux-amd64`) so 21 and 23 don't share cache entries.
- `merge` job: `:latest` only when the version equals `LATEST_VERSION`
  (`flavor: latest=false` plus `type=raw,value=latest,enable=…`, as the family does). The rest of the
  merge job (single-digest manifest list for 21, signing, attestations, verification, README sync)
  works unchanged for one platform.
- Add an `oracle_version` input to `workflow_dispatch` (build-only, never publishes).
- *(Builder's call, from review.)* Tighten `IS_RELEASE` to **tag pushes only**
  (`github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')`), and gate the `merge` job
  the same way. Today a `workflow_dispatch` run started on a tag ref would publish, which
  contradicts "dispatch never publishes".
- *(Builder's call.)* A `workflow_dispatch` with no input, and pushes to `master` / `oracle-*`
  branches, build all versions, the same as PRs.
- Update the `.github/dependabot.yml` comment that refers to `ORACLE_VERSION`. (Dependabot already
  tracks the Docker ecosystem; with literal `FROM` lines it can bump both pins.)
- `master` has no required status checks (its only ruleset rule blocks deletion), so renaming the
  matrix jobs doesn't affect merging.

### Smoke test

In the `build` job, after building, on every run (PR, branch, dispatch, release):

- Run the image, wait for `healthy` (bounded wait; fail on `unhealthy` or timeout).
- As `sakila` over the listener at `//localhost:1521/SAKILA`, assert: 16 tables, 7 views, the four
  key row counts, and `staff.picture` length 36,365. Fail the job on any mismatch.
- **View output matches golden hashes** (maintainer's decision). For each of the 7 views, select all
  rows with fixed SQL\*Plus settings, sort, and SHA-256 the result (the spike's method: `PAGESIZE 0`,
  `LINESIZE 32767`, `TRIMSPOOL`/`TRIMOUT ON`, `FEEDBACK OFF`, `HEADING OFF`, `COLSEP '|'`). Compare
  against a committed fixture (e.g. `testdata/view-hashes.txt`), shared by every version. The spike's
  values are the baseline (21 and 23 matched exactly):

  ```
  actor_info                  44f52eb07dacd769
  customer_list               24f84126ca2aab2e
  film_list                   40fde8d8f576b6c4
  nicer_but_slower_film_list  67c7c97d7a954dc5
  sales_by_film_category      1b272fafa1574448
  sales_by_store              fe5bf28767683d86
  staff_list                  06dd5a71f4de2a3d
  ```

  (Those are 16-hex-char prefixes. The builder may store full hashes, regenerated the same way.)
  Because the fixture is shared, the 23 build of the new data-file format also proves its contents are
  unchanged. A schema change that alters view output must update the fixture in the same commit,
  alongside `sq`'s expectations. Document this in CLAUDE.md.
- On failure, dump the container's health log and `docker logs`.
- Release ordering: build with `load: true` and smoke-test **before** the push-by-digest step, so a
  broken image is never pushed. The push step reuses the same builder cache, so it doesn't rebuild.

### PRs build every version

PRs and `master` pushes build **all** versions (23 on both arches, 21 on amd64), not just
`LATEST_VERSION`. This deviates from the family pattern on purpose: the spike showed 21c rejects SQL
that 23 accepts, so a 23-only PR check can't satisfy the anti-goal. Cost: one extra amd64 job of
~2.5 minutes. (A `workflow_dispatch` with an input still builds only that version. Tag pushes build
only the tag's version.)

### Docs

- README: add the 21 row to "Available versions" (amd64 only, no `:latest`), a short note that 21 is a
  19c stand-in on a base that Oracle no longer patches, the `--build-arg ORACLE_MAJOR=21` local build,
  and a changelog entry.
- CLAUDE.md: the multi-version build, the base-per-version stages, the 21c constraints above
  (`INSERT` form, 3000-char lines, `SP2-` not trapped), and the release steps for 21.

## Sequencing

1. The echo-off fix (`fix/quiet-data-load`) lands first as its own PR; this work rebases onto it.
2. This work lands as one PR to `master`.
3. Release `v23.0.8` (23 rebuilt with the new data-file format; contents unchanged), then `v21.0.0`.
   Each release self-verifies; confirm `:latest` still points at 23 after `v21.0.0`.
4. Delete the `spike/21c-xe` branch.
5. Follow-up outside this repo: point `sq`'s Oracle CI at `:21` as well as `:23` (cross-repo, not
   part of this work).

## Left to the builder

- Exact shape of the `setup` job's JSON and how `build` consumes it.
- Whether the smoke test lives inline in the workflow or in a script (e.g. `scripts/smoke-test.sh`)
  that `make` can also run locally.
- Bounded-wait timings for the smoke test (the spike saw 20–30s to `healthy`).
- Exact README wording and table formatting.
