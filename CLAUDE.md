# CLAUDE.md

Maintainer guide for **`sakiladb/oracle`** — an Oracle Database 23ai Free Docker image preloaded with
the [Sakila](https://dev.mysql.com/doc/sakila/en/) sample database (hand-ported from the MySQL Sakila
via [jOOQ](https://www.jooq.org/sakila)), published to
[Docker Hub](https://hub.docker.com/r/sakiladb/oracle) and
[GitHub Container Registry](https://github.com/sakiladb/oracle/pkgs/container/oracle).

> One of the [`sakiladb`](https://github.com/sakiladb) image family (`postgres`, `mysql`,
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

Stored procedures, functions, and triggers are intentionally **omitted** (faithful to jOOQ's Oracle
port; `sq`-invisible). `staff.picture` (BLOB) and `address.location` (spatial) are also omitted.

## How the image is built

*(Oracle-specific.)* `Dockerfile` is a two-stage build that **bakes the Oracle data directory**
(postgres-style), so the DB is ready within seconds of `docker run` (no init at start):

1. **`builder` stage** — `FROM gvenzl/oracle-free:slim-faststart`. `ORACLE_DATABASE=SAKILA` makes
   gvenzl's entrypoint clone a `SAKILA` PDB + create the app user; `init-as-sakila.sh` then loads the
   schema/data/finalize **as the `sakila` app user** into `SAKILA`, drops the unused seed `FREEPDB1`,
   and shuts down cleanly so the data files are quiesced before the layer is committed.
2. **final stage** — copies the pre-loaded `/opt/oracle/oradata`; gvenzl's entrypoint detects the
   initialized DB and starts straight into it.

| File | Role |
|------|------|
| `1-oracle-sakila-schema.sql` | Tables (incl. `film_text`), indexes, views. |
| `2-oracle-sakila-data.sql` | Data (`INSERT … VALUES`), generated from the vendored MySQL dump by `convert_data.py`. |
| `3-oracle-sakila-finalize.sql` | FKs (added after the data load), `film_text` populate, identity high-water realign, and a **row-count tripwire** that fails the build on drift. |

> **Why `init-as-sakila.sh` (not `/container-entrypoint-initdb.d/`):** gvenzl runs `*.sql` there as
> SYSDBA against the CDB, but the Sakila objects must be owned by the `sakila` app user inside the
> `SAKILA` PDB, so the shim opens its own `sqlplus` session as the app user.

### Readiness (HEALTHCHECK)

Readiness comes from the **gvenzl base image's built-in `HEALTHCHECK`** (it reports `healthy` once the
DB is open and serving) — no override needed. The family's readiness contract (`healthy` = ready to
serve) holds.

## How releases work

*(Shared across the family — see [`sakiladb/postgres`](https://github.com/sakiladb/postgres)'s CLAUDE.md.)*
Releases are **tag-driven**: a single `master` branch, and pushing a semver tag `vN.0.x` publishes
Oracle N. The workflow builds **natively for both arches** (amd64 on `ubuntu-latest`, arm64 on
`ubuntu-24.04-arm` — QEMU isn't faithful enough for Oracle's PMON to start), pushes **by digest** to
**Docker Hub + GHCR**, merges a multi-arch manifest tagged `:{major}` (+ `:latest`), and **cosign**-signs.

## Conventions

- **Credentials:** PDB / user / password = `SAKILA` / `sakila` / `p_ssW0rd`.
- **Tags:** Docker tag is the Oracle major (`23`); `latest` on the newest. Git tags are
  `v{MAJOR}.{MINOR}.{PATCH}` — the major tracks the Oracle version, minor/patch track sakiladb's own
  revisions (in practice only the patch moves: `v23.0.0` → `v23.0.1`).
- **No AI attribution** in commits, tags, PRs, or any other content.
