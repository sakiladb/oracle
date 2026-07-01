# sakiladb/oracle

An Oracle Database 23ai Docker image preloaded with the [Sakila](https://dev.mysql.com/doc/sakila/en/)
sample database (hand-ported via [jOOQ](https://www.jooq.org/sakila)). One of the
[`sakiladb`](https://github.com/sakiladb) image family.

These images exist primarily as test fixtures for [`sq`](https://github.com/neilotoole/sq), a
command-line tool for querying SQL databases and structured data, but they are free for anyone to
use. See sq's [driver guides](https://sq.io/docs/drivers/).

Available on [Docker Hub](https://hub.docker.com/r/sakiladb/oracle) and
[GitHub Container Registry](https://github.com/sakiladb/oracle/pkgs/container/oracle).

## Quick start

```shell
docker run -p 1521:1521 -d sakiladb/oracle:latest
```

The image is built on [`gvenzl/oracle-free`](https://hub.docker.com/r/gvenzl/oracle-free) (pinned to
`23.26.2-slim-faststart`) with the Oracle data directory pre-baked, so the database is ready to query
within seconds of container start, with no initialization step.

The image declares a Docker
[`HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck), so you can wait for
readiness rather than guessing. Its status becomes `healthy` once the `SAKILA` pluggable database is
open and queryable:

```shell
docker run -p 1521:1521 -d --name sakila sakiladb/oracle:latest
until [ "$(docker inspect -f '{{.State.Health.Status}}' sakila)" = healthy ]; do sleep 1; done
```

In Docker Compose, gate dependents with `depends_on: { condition: service_healthy }`.

> [!TIP]
> Building or testing on GitHub Actions? Pull from GHCR (`ghcr.io/sakiladb/oracle`). Docker Hub
> rate-limits pulls and CI runners share IP addresses, so the limit is reached quickly; GHCR isn't
> throttled the same way, especially from within GitHub's network.

## Connection

| Setting        | Value       |
|----------------|-------------|
| host           | `localhost` |
| port           | `1521`      |
| service (PDB)  | `SAKILA`    |
| user / schema  | `sakila`    |
| password       | `p_ssW0rd`  |

Any Oracle client works with the settings above. For example, with
[`sq`](https://github.com/neilotoole/sq) ([install](https://sq.io/docs/install)):

```shell
$ sq add 'oracle://sakila:p_ssW0rd@localhost:1521/SAKILA' --handle @sakila_or
@sakila_or  oracle  sakila@localhost:1521/SAKILA

$ sq '@sakila_or.actor | .[0:5]'
ACTOR_ID  FIRST_NAME  LAST_NAME     LAST_UPDATE
1         PENELOPE    GUINESS       2006-02-15T04:34:33Z
2         NICK        WAHLBERG      2006-02-15T04:34:33Z
3         ED          CHASE         2006-02-15T04:34:33Z
4         JENNIFER    DAVIS         2006-02-15T04:34:33Z
5         JOHNNY      LOLLOBRIGIDA  2006-02-15T04:34:33Z
```

For JDBC:

```
jdbc:oracle:thin:@//localhost:1521/SAKILA
user=sakila
password=p_ssW0rd
```

## What's inside

The standard Sakila sample database: **16 tables and 7 views**, owned by the `sakila` user (the
schema *is* the user).

[`sq inspect`](https://sq.io/docs/inspect) shows the whole schema (tables, views, row counts, and
columns) at a glance:

```shell
$ sq inspect @sakila_or
SOURCE      DRIVER  NAME    FQ NAME        SIZE   TABLES  VIEWS  LOCATION
@sakila_or  oracle  SAKILA  SAKILA.SAKILA  9.3MB  16      7      oracle://sakila:xxxxx@localhost:1521/SAKILA

NAME                        TYPE   ROWS   COLS
ACTOR                       table  200    ACTOR_ID, FIRST_NAME, LAST_NAME, LAST_UPDATE
ADDRESS                     table  603    ADDRESS_ID, ADDRESS, ADDRESS2, DISTRICT, CITY_ID, POSTAL_CODE, PHONE, LAST_UPDATE
CATEGORY                    table  16     CATEGORY_ID, NAME, LAST_UPDATE
CITY                        table  600    CITY_ID, CITY, COUNTRY_ID, LAST_UPDATE
COUNTRY                     table  109    COUNTRY_ID, COUNTRY, LAST_UPDATE
CUSTOMER                    table  599    CUSTOMER_ID, STORE_ID, FIRST_NAME, LAST_NAME, EMAIL, ADDRESS_ID, ACTIVE, CREATE_DATE, LAST_UPDATE
FILM                        table  1000   FILM_ID, TITLE, DESCRIPTION, RELEASE_YEAR, LANGUAGE_ID, ORIGINAL_LANGUAGE_ID, RENTAL_DURATION, RENTAL_RATE, LENGTH, REPLACEMENT_COST, RATING, SPECIAL_FEATURES, LAST_UPDATE
FILM_ACTOR                  table  5462   ACTOR_ID, FILM_ID, LAST_UPDATE
FILM_CATEGORY               table  1000   FILM_ID, CATEGORY_ID, LAST_UPDATE
FILM_TEXT                   table  1000   FILM_ID, TITLE, DESCRIPTION
INVENTORY                   table  4581   INVENTORY_ID, FILM_ID, STORE_ID, LAST_UPDATE
LANGUAGE                    table  6      LANGUAGE_ID, NAME, LAST_UPDATE
PAYMENT                     table  16049  PAYMENT_ID, CUSTOMER_ID, STAFF_ID, RENTAL_ID, AMOUNT, PAYMENT_DATE, LAST_UPDATE
RENTAL                      table  16044  RENTAL_ID, RENTAL_DATE, INVENTORY_ID, CUSTOMER_ID, RETURN_DATE, STAFF_ID, LAST_UPDATE
STAFF                       table  2      STAFF_ID, FIRST_NAME, LAST_NAME, ADDRESS_ID, PICTURE, EMAIL, STORE_ID, ACTIVE, USERNAME, PASSWORD, LAST_UPDATE
STORE                       table  2      STORE_ID, MANAGER_STAFF_ID, ADDRESS_ID, LAST_UPDATE
ACTOR_INFO                  view   200    ACTOR_ID, FIRST_NAME, LAST_NAME, FILM_INFO
CUSTOMER_LIST               view   599    ID, NAME, ADDRESS, zip code, PHONE, CITY, COUNTRY, NOTES, SID
FILM_LIST                   view   997    FID, TITLE, DESCRIPTION, CATEGORY, PRICE, LENGTH, RATING, ACTORS
NICER_BUT_SLOWER_FILM_LIST  view   997    FID, TITLE, DESCRIPTION, CATEGORY, PRICE, LENGTH, RATING, ACTORS
SALES_BY_FILM_CATEGORY      view   16     CATEGORY, TOTAL_SALES
SALES_BY_STORE              view   2      STORE, MANAGER, TOTAL_SALES
STAFF_LIST                  view   2      ID, NAME, ADDRESS, zip code, PHONE, CITY, COUNTRY, SID
```

## Differences from other sakila variants

The object set and data match the family (the view output is byte-identical to the other variants),
but Oracle's idioms and a few engine constraints produce these differences:

- **`film_text` is populated but kept plain (no full-text index).** An Oracle Text `CONTEXT` index
  creates several `DR$` auxiliary tables in the schema, which would break the uniform 16-table count,
  so (like SQLite's FTS5) full-text search is omitted here.
- **`staff.picture` (BLOB) is present**, like the rest of the family. Sakila's only binary column (a
  ~36 KB PNG on `staff_id = 1`; `staff_id = 2` is `NULL`) is stored in a real Oracle `BLOB` and
  inspects as a `bytes` column. Because the image exceeds Oracle's 4000-byte SQL string-literal limit,
  it is loaded in one place via a `DBMS_LOB` chunked reassembly (see `2-oracle-sakila-data.sql`) rather
  than an inline `INSERT`. **`address.location` (GEOMETRY) is omitted** (dropped across the whole
  family).
- **Aggregating views use Oracle idioms:** `film_list` uses `LISTAGG` (deterministically ordered)
  rather than the MySQL original's `GROUP_CONCAT`; `nicer_but_slower_film_list` title-cases with
  `INITCAP`; `actor_info` uses a nested `LISTAGG`.
- **`film.special_features`** is stored as a comma-separated `VARCHAR2(100)` rather than a `SET` or
  array, matching what other Sakila ports do.
- **`active` is `NUMBER(1)` with a `CHECK (active IN (0,1))`** on both `customer` and `staff`.
- **Identifiers fold upper-case** (Oracle's default), so `sq inspect` shows `ACTOR`, `FILM_ID`, and so
  on; the views deliberately keep the canonical mixed-case aliases (`ID`, `SID`, `FID`, `"zip code"`).
- **Stored procedures, functions, and triggers are not ported** (faithful to jOOQ's Oracle port; they
  are MySQL-specific PL/SQL and `sq`-invisible). Identity column high-water marks are realigned to
  `MAX(id)+1` after the data load, so later `INSERT`s without explicit ids will not collide.

## Available versions

Each Oracle major version is published as its own image tag. `latest` tracks the newest version
(currently 23).

| Oracle | sakiladb Release | Architecture     | Docker Hub                                                                                              | GitHub Container Registry                                                                                                              |
|--------|------------------|------------------|--------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
| 23     | `v23.0.7`        | `amd64`, `arm64` | [`sakiladb/oracle:23`](https://hub.docker.com/r/sakiladb/oracle), [`:latest`](https://hub.docker.com/r/sakiladb/oracle) | [`ghcr.io/sakiladb/oracle:23`](https://github.com/sakiladb/oracle/pkgs/container/oracle), [`:latest`](https://github.com/sakiladb/oracle/pkgs/container/oracle) |

The image tag tracks the **Oracle major version** (matching `sakiladb/postgres:15`, `sakiladb/mysql:8`,
…). **sakiladb Release** is the git tag the current image was built from (see
[releases](https://github.com/sakiladb/oracle/releases)); the version is `v{MAJOR}.{MINOR}.{PATCH}`
with the **major** tracking Oracle and the **minor**/**patch** tracking sakiladb's own revisions (so
successive `v23.x.y` releases all surface as `:23`). Every version is published to both
[Docker Hub](https://hub.docker.com/r/sakiladb/oracle) and
[GitHub Container Registry](https://github.com/sakiladb/oracle/pkgs/container/oracle), built natively
for both arches (QEMU is not faithful enough for Oracle's PMON to start), and signed with
[cosign](https://github.com/sigstore/cosign). Each image also carries
[SLSA build provenance](https://slsa.dev/) and an SPDX [SBOM](https://spdx.dev/) attestation
(verify with `gh attestation verify`).

## Releasing a new version

Maintainers: releases are tag-driven. Pushing a semver tag `vN.x.y` builds and publishes that Oracle
major version. To build the image locally, run `make build` (`make help` lists all targets). See
[CLAUDE.md](./CLAUDE.md) for the full, repeatable procedure.

## Verifying a pulled image

Every published tag carries a Sigstore signature tying it to this repository's GitHub Actions
workflow. To verify:

```shell
cosign verify \
  --certificate-identity-regexp 'https://github.com/sakiladb/oracle/.+' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  sakiladb/oracle:23
```

A successful verification confirms the image was built from this repository's workflow on a tag push
and has not been tampered with in transit.

## Changelog

### 2026-06-30

- **Supply-chain attestations** (`v23.0.7`; releases now self-verify their attestations): published images now carry
  [SLSA build provenance](https://slsa.dev/) and an SPDX [SBOM](https://spdx.dev/)
  attestation, alongside the existing cosign signature (as OCI referrers on Docker
  Hub and GHCR and in GitHub's attestation store; verify with `gh attestation verify`).
  The README is also synced to the Docker Hub description on release.
- **Restored the `staff.picture` BLOB column** (`v23.0.5`). Sakila's only binary column is now carried
  faithfully in a real Oracle `BLOB` (the ~36 KB PNG on `staff_id = 1`; `staff_id = 2` is `NULL`), so
  `staff` matches the canonical 11-column schema and inspects as a `bytes` column. The image is
  reassembled at build time from hex chunks via `DBMS_LOB` (it exceeds Oracle's 4000-byte string
  literal limit). Oracle no longer diverges from the family on this column; ClickHouse remains the sole
  variant without it (it has no native binary type).

### 2026-06-28

- **Maintenance release** (`v23.0.4`): documentation only (README aligned with the family template).
  The Sakila dataset and schema are unchanged from the previous release.
- **Added a Docker `HEALTHCHECK`** (`v23.0.3`): the container now reports `healthy` once the `SAKILA`
  PDB is open and queryable (`/opt/oracle/healthcheck.sh SAKILA`).
- **Pinned the base image** to an exact Oracle Free release (`23.26.2-slim-faststart`) via
  `ARG ORACLE_VERSION`, so rebuilds are reproducible (the previously floating `slim-faststart` tag had
  silently drifted the engine across rebuilds).

### 2026-06-26

- **Restored faithful original data** (`v23.0.2`). The Sakila data is now byte-identical to the
  original MySQL Sakila: the Unicode accents stripped from international place names (e.g. `Réunion`,
  `Coruña`) are restored.
- **Reconciled to the consistent sakiladb fixture: 16 tables + 7 views.** Added `film_text`
  (populated, plain) and the `actor_info` (nested `LISTAGG`) and `nicer_but_slower_film_list`
  (`INITCAP`) views; made `film_list`'s cast order deterministic; `customer_list` / `staff_list` use
  the canonical `zip code`. The view output is byte-identical to the other variants.

## License

[MIT](./LICENSE).
