# AGENTS.md

Guide for maintainers and coding agents working on **`sakiladb/oracle`** — Oracle Database Docker images (23ai Free as `:23`, and
21c XE as `:21`, a 19c stand-in; see [Versions and base images](#versions-and-base-images)) preloaded with
the [Sakila](https://dev.mysql.com/doc/sakila/en/) sample database (hand-ported from the MySQL Sakila
via [jOOQ](https://www.jooq.org/sakila)), published to
[Docker Hub](https://hub.docker.com/r/sakiladb/oracle) and
[GitHub Container Registry](https://github.com/sakiladb/oracle/pkgs/container/oracle).

> One of the [`sakiladb`](https://github.com/sakiladb) image family (`postgres`, `mysql`, `mariadb`,
> `sqlserver`, `oracle`, `clickhouse`, `rqlite`). The release machinery in
> [How releases work](#how-releases-work) is **shared across the family** (the reference template
> lives in [`sakiladb/postgres`](https://github.com/sakiladb/postgres)); the build details in
> [How the image is built](#how-the-image-is-built) are **Oracle-specific**.

## Purpose

These images exist primarily as **test fixtures for the [`sq`](https://github.com/neilotoole/sq) CLI**.
`sq`'s suite runs against every variant and asserts a uniform Sakila schema, so each image must expose
the **same object set: 16 tables + 7 views**. Treat that as a hard consistency contract.

Because the schema is coupled to `sq`'s tests, **a schema change here is a cross-repo change**: `sq`'s
expectations (`testh/sakila/sakila.go`, `libsq/driver/driver_test.go`, `cli/cmd_inspect_test.go`) must
be updated in lockstep or its suite breaks against the new image.

## The dataset

The standard Sakila database, in the `SAKILA` pluggable database, owned by the `sakila` user (the
schema *is* the user): **16 tables + 7 views**, reconciled to the canonical `sakiladb/mysql` (view
output verified byte-identical to postgres/mysql). Oracle-specific points:

- **`film_text` is present and populated, but kept PLAIN** — no full-text index. This is the one place
  oracle can't follow the family's "FTS as an invisible index" rule: an Oracle Text `CTXSYS.CONTEXT`
  index creates ~7 **`DR$` auxiliary tables** in the schema, which `sq` would count — breaking the
  16-table contract (exactly like SQLite's FTS5 virtual tables). So oracle joins the SQLite family as
  FTS-less. (Because no Oracle Text is needed, the base stays the smaller `slim-faststart`.)
- **`film_list` orders its `LISTAGG` deterministically** (`ORDER BY first_name, last_name, actor_id`)
  so the cast string is byte-identical to the family.
- **`actor_info` + `nicer_but_slower_film_list` added** (→ 7 views). `actor_info` uses a nested
  `LISTAGG` (a correlated scalar subquery of categories wrapping an inner `LISTAGG` of titles — max
  `film_info` is ~830 chars, well within Oracle's 4000-byte `VARCHAR2` `LISTAGG` limit). `nicer` uses
  `INITCAP` for title-casing (the cleanest in the family).
- **`active` is `NUMBER(1)` + a `CHECK (active IN (0,1))`** on both `customer` and `staff` — already
  consistent, so it's left as-is (Oracle 23ai's real `BOOLEAN` is an optional future modernization, not
  a parity defect).
- **`customer_list` / `staff_list` use `"zip code"`** (quoted, the canonical spaced identifier).

- **`staff.picture` (BLOB) is present.** Oracle has a real `BLOB` type, so Sakila's only binary column
  (a ~36 KB PNG on `staff_id = 1`) is carried faithfully and inspects as `bytes`. The image is ~18x
  over Oracle's 4000-byte SQL string-literal limit, so `convert_data.py` keeps the inline `INSERT`'s
  `picture` `NULL` and emits a trailing `DBMS_LOB.WRITEAPPEND` reassembly into `2-oracle-sakila-data.sql`,
  followed by a tripwire (emitted by the same generator) asserting the loaded length and PNG
  header/trailer bytes. ClickHouse is the only family member still without this column (no native
  binary type).

Stored procedures, functions, and triggers are intentionally **omitted** (faithful to jOOQ's Oracle
port; `sq`-invisible). `address.location` (spatial) is also omitted.

## How the image is built

*(Oracle-specific.)* `Dockerfile` is a two-stage build that **bakes the Oracle data directory**
(postgres-style), so the DB is ready within seconds of `docker run` (no init at start):

1. **`builder` stage** — `FROM base-${ORACLE_MAJOR}`, one of the pinned per-version base stages (see
   below). `ORACLE_DATABASE=SAKILA` makes
   gvenzl's entrypoint clone a `SAKILA` PDB + create the app user; `init-as-sakila.sh` then loads the
   schema/data/finalize **as the `sakila` app user** into `SAKILA`, drops the base's unused default
   PDB (`FREEPDB1` on 23ai Free, `XEPDB1` on 21c XE — detected, not hard-coded: every PDB other than
   `SAKILA` and `PDB$SEED`), and shuts down cleanly so the data files are quiesced before the layer
   is committed.
2. **final stage** — copies the pre-loaded `/opt/oracle/oradata`; gvenzl's entrypoint detects the
   initialized DB and starts straight into it.

| File | Role |
|------|------|
| `1-oracle-sakila-schema.sql` | Tables (incl. `film_text`), indexes, views. |
| `2-oracle-sakila-data.sql` | Data, one `INSERT … VALUES (…);` per row, generated from the vendored MySQL dump by `convert_data.py` (`make convert-data`). Never edit it by hand: a unit test fails if it differs from the generator's output. |
| `3-oracle-sakila-finalize.sql` | FKs (added after the data load), `film_text` populate, identity high-water realign, and a **row-count tripwire** that fails the build on drift. |

### Versions and base images

Two Oracle majors are built from the same `master`, the same SQL files and the same `Dockerfile`.
`ARG ORACLE_MAJOR` (default `23`) selects one of two **pinned base stages**:

| Major | Base stage | Base image | Platforms | Docker tags |
|-------|-----------|-----------|-----------|-------------|
| 23 | `base-23` | `gvenzl/oracle-free:23.26.2-slim-faststart` | amd64, arm64 | `:23`, `:latest` |
| 21 | `base-21` | `gvenzl/oracle-xe:21.3.0-slim-faststart` | amd64 only (the XE base is amd64-only) | `:21` |

Each pin is an exact gvenzl release in the smaller `slim-faststart` variant (FTS-less, see
[The dataset](#the-dataset)), never a floating tag, so rebuilds are reproducible (a floating tag once
silently drifted the engine across rebuilds). The tags are literal in the `Dockerfile`'s
`FROM … AS base-NN` lines, so Dependabot can bump them. **To move to a newer Oracle release, bump that
stage's tag**; the published Docker tag stays the major. 21.3.0 is the final 21c XE release, so the 21
pin won't move. Build locally with `make build` (23) or `make build ORACLE_MAJOR=21` (amd64 hosts
only: Oracle doesn't run under emulation).

**23ai vs 26ai.** Oracle has renamed 23ai to *Oracle AI Database 26ai* but kept the 23 version
number: `23.26.2` is major 23, release update 26.2. So the `:23` image's banner reads
`Oracle AI Database 26ai Free Release 23.26.2.0.0`. Tags follow the version number, not the
marketing name: it stays `:23` (and `v23.x.y`), and there is no `:26`. These docs say "23ai"
throughout.

**21 is a 19c stand-in.** 19c is what most Oracle users run, but it has no free edition. 21c is the
closest version that can be published, and like 19c it lacks 23ai's `VECTOR` and SQL `BOOLEAN`. (It
does have the native `JSON` type, which arrived in 21c, so JSON-type code that works on `:21` may
still fail on 19c.) Oracle's patching for 21c ended in April 2025.

**Adding a version** means a new `base-NN` stage in the `Dockerfile` plus a row in
`.github/scripts/resolve-version.sh` (the only place the version → platforms table lives).

> **21c constraints the SQL must respect** (both versions run the same files; found in the #11 spike):
> - **No multi-row `INSERT … VALUES (…),(…)`.** That syntax is 23ai-only (21c raises `ORA-00933`),
>   so `convert_data.py` emits one `INSERT` per row. (It's also faster on 23.)
> - **SQL\*Plus script lines must be ≤2999 characters.** 21c's SQL\*Plus rejects longer ones
>   (`SP2-0341`; 23ai's limit is 4999). The `staff.picture` BLOB is written in 1000-byte
>   `DBMS_LOB.WRITEAPPEND` chunks for this reason, and `convert_data.py` fails if any line it emits is
>   longer.
> - **`SP2-` errors don't trip `WHENEVER SQLERROR EXIT`.** SQL\*Plus skips the statement and keeps
>   going. The post-load tripwires (BLOB length/signature, row counts) are what catch a skipped
>   statement; keep them.

> **Why `init-as-sakila.sh` (not `/container-entrypoint-initdb.d/`):** gvenzl runs `*.sql` there as
> SYSDBA against the CDB, but the Sakila objects must be owned by the `sakila` app user inside the
> `SAKILA` PDB, so the shim opens its own `sqlplus` session as the app user.

### Readiness (HEALTHCHECK)

The final stage declares an explicit `HEALTHCHECK` that runs the gvenzl base's `healthcheck.sh`
against the **`SAKILA`** PDB (`CMD ["/opt/oracle/healthcheck.sh", "SAKILA"]`), so the container reports `healthy`
once that PDB is open and the baked schema is queryable. The base's `slim-faststart` variant ships
the script but does **not** wire it as a `HEALTHCHECK`, and bare it defaults to the base's default
PDB (`FREEPDB1` or `XEPDB1`) — which this image drops — so the explicit `SAKILA` arg is required. A generous `--start-period` (90s,
mirroring sqlserver) covers Oracle's slow PDB-open settle.

> **Family convention:** every `sakiladb` image declares a `HEALTHCHECK` using its engine's native
> probe (`pg_isready`, `mysqladmin ping`, `sqlcmd … SELECT 1`, `healthcheck.sh SAKILA`, …). The probe
> differs per engine; the readiness *contract* (`healthy` = ready to serve) is uniform.

### Smoke test (`smoke-test.sh`)

CI runs every image it builds through `./smoke-test.sh IMAGE` **before anything is pushed**
(`make test` runs it locally against `$(IMAGE)`). It starts its own container, waits for `healthy`,
and checks, as `sakila` over the listener: 16 tables + 7 views, the key row counts, the
`staff.picture` BLOB, and that each view's full output hashes to the committed
**`testdata/view-hashes.txt`**. That fixture is shared by both versions, so 21c and 23ai must return
byte-identical view output.

**A schema change that alters view output must update `testdata/view-hashes.txt` in the same commit**
(`make update-view-hashes IMAGE=…`), in lockstep with `sq`'s expectations. The hash depends on the
script's fixed SQL\*Plus settings and a C-locale `sort`; changing either changes every hash.

## How releases work

*(Shared across the family — see [`sakiladb/postgres`](https://github.com/sakiladb/postgres)'s CLAUDE.md.)*
Releases are **tag-driven**: a single `master` branch, and pushing a semver tag `vN.0.x` publishes
Oracle N (`v23.0.8` → `:23`, `v21.0.0` → `:21`). The workflow builds **natively per arch** (amd64 on
`ubuntu-latest`, arm64 on `ubuntu-24.04-arm` — QEMU isn't faithful enough for Oracle's PMON to start),
smoke-tests each image, pushes **by digest** to **Docker Hub + GHCR**, merges a manifest list tagged
`:{major}`, and **cosign**-signs, attests and self-verifies.

*(Oracle-specific.)* A `setup` job runs the unit tests (`make unit-test`) and
`.github/scripts/resolve-version.sh`, which turns the ref into the build matrix:

- **Tag push** → the tag's major only. **The only event that publishes** (a manual run on a tag
  ref doesn't).
- **Manual run** (`workflow_dispatch`, input `oracle_version`) → that version, or every version if
  blank. Never publishes.
- **PRs and branch pushes** → **every version**. This deliberately departs from the family, which
  builds only the newest on PRs: 21c rejects SQL that 23ai accepts, so a 23-only check would let a
  21-breaking change through.

`:latest` goes only to `LATEST_VERSION` (`23`, set in the workflow), whatever order tags are pushed in:
`v21.0.x` publishes `:21` and leaves `:latest` alone.

## Conventions

- **Credentials:** PDB / user / password = `SAKILA` / `sakila` / `p_ssW0rd`.
- **Tags:** Docker tag is the Oracle major (`23`, `21`); `latest` on the newest (`LATEST_VERSION`). Git tags are
  `v{MAJOR}.{MINOR}.{PATCH}` — the major tracks the Oracle version, minor/patch track sakiladb's own
  revisions (in practice only the patch moves: `v23.0.0` → `v23.0.1`).
- **No AI attribution** in commits, tags, PRs, or any other content.
