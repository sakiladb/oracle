# sakiladb/oracle

Oracle Database 23ai docker image preloaded with the [Sakila](https://dev.mysql.com/doc/sakila/en/)
example database (by way of [jOOQ](https://www.jooq.org/sakila)).
See on [Docker Hub](https://hub.docker.com/r/sakiladb/oracle).

By default these are created:
- pluggable database: `SAKILA`
- username / password: `sakila` / `p_ssW0rd`
- schema (= app user): `sakila`

## Quick Start

```shell
docker run -p 1521:1521 -d sakiladb/oracle:latest
```

Or pin to a specific Oracle major version (see all available image tags on
[Docker Hub](https://hub.docker.com/r/sakiladb/oracle/tags)):

```shell
docker run -p 1521:1521 -d sakiladb/oracle:23
```

The image is built on top of [`gvenzl/oracle-free:slim-faststart`](https://hub.docker.com/r/gvenzl/oracle-free)
and ships with the data directory pre-populated, so the database is ready to
query within seconds of container start.

### Image tag convention

The image tag tracks the **Oracle Database major version** the image targets,
matching the convention used by the other `sakiladb/*` repositories
(`sakiladb/postgres:15`, `sakiladb/mysql:8`, `sakiladb/clickhouse:25`, …).

Releases are cut as semver git tags of the form `vMAJOR.MINOR.PATCH`, where
`MAJOR` is the Oracle major version. Each tag push produces both `:<MAJOR>`
and `:latest` on both registries:

| Git tag   | Docker tag(s) published                                       |
|-----------|---------------------------------------------------------------|
| `v23.0.0` | `:23`, `:latest` on Docker Hub and GHCR                       |
| `v23.1.0` | `:23`, `:latest` (both overwritten in place)                  |
| `v23.0.1` | `:23`, `:latest` (both overwritten in place)                  |

`MINOR` / `PATCH` are reserved for iterations of *this* image (schema fixes,
packaging tweaks) on the same Oracle major. Bumping them does not change the
Docker tag — successive `v23.x.y` releases all surface as `:23`. A new Oracle
major (e.g. a hypothetical Oracle Free 24) would land as `v24.0.0` →
`sakiladb/oracle:24` and would also shift `:latest`.

## Releases

Images are published by GitHub Actions
([`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml))
on every push of a `vMAJOR.MINOR.PATCH` tag. Pushes to branches and pull
requests only run a validation build — they don't push anything to a
registry. Cutting a release is therefore a two-step thing:

```shell
git tag v23.0.0
git push origin v23.0.0
```

What the release pipeline does, in order:

1. **Build natively for both architectures** in parallel — `linux/amd64`
   on `ubuntu-latest`, `linux/arm64` on `ubuntu-24.04-arm`. (QEMU emulation
   isn't faithful enough for Oracle's PMON to start.)
2. **Push by digest** to both Docker Hub and GHCR.
3. **Merge** the per-platform digests into a multi-arch manifest list,
   tagged `:<MAJOR>` and `:latest` on each registry.
4. **Sign with cosign** (keyless, via Sigstore Fulcio + Rekor — no
   long-lived signing keys). Both the multi-arch index and the per-arch
   image manifests are signed.

### Registries

| Registry  | Pull URL                       |
|-----------|--------------------------------|
| Docker Hub | `docker.io/sakiladb/oracle`    |
| GHCR       | `ghcr.io/sakiladb/oracle`      |

The two registries publish bit-for-bit identical images (same layer
digests) — pick whichever has lower latency for your environment.

### Verifying a pulled image

Every published tag carries a Sigstore signature tying it to this
repository's GitHub Actions workflow. To verify:

```shell
cosign verify \
  --certificate-identity-regexp 'https://github.com/sakiladb/oracle/.+' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  sakiladb/oracle:23
```

A successful verification confirms the image was built from this
repository's workflow on a tag push, and hasn't been tampered with in
transit.

## Build Locally

The included `Makefile` wraps the common docker workflows. Run `make help`
to list targets; the most useful are:

| Target            | What it does                                              |
|-------------------|-----------------------------------------------------------|
| `make build`      | Build the image as `sakiladb/oracle:latest`               |
| `make run`        | Start the image as a detached container on `:1521`        |
| `make sqlplus`    | Open `sqlplus` inside the running container as `sakila`   |
| `make stop`       | Stop and remove the running container                     |
| `make logs`       | Tail container logs                                       |
| `make convert-data` | Regenerate `2-oracle-sakila-data.sql` from the MySQL dump |

Variables (`IMAGE`, `CONTAINER`, `PORT`, `PDB`, `USER`, `PASSWORD`) can be
overridden on the command line, e.g. `make run PORT=1522`.

Or step by step:

```shell
# Only needed if mysql-sakila-data.sql changes; 2-oracle-sakila-data.sql is committed.
python3 convert_data.py mysql-sakila-data.sql 2-oracle-sakila-data.sql
docker build -t sakiladb/oracle:latest .
```

The upstream MySQL data dump is vendored as `mysql-sakila-data.sql` so the
build is self-contained — no sibling repo checkout required.

## Ports

- `1521`: Oracle Net listener (TCP)

## Verify Installation

Using `sqlplus` from inside the container:

```shell
docker exec -it $(docker ps -q -f ancestor=sakiladb/oracle:latest) \
    sqlplus sakila/p_ssW0rd@//localhost:1521/SAKILA \
    <<< "SELECT actor_id, first_name, last_name FROM actor FETCH FIRST 5 ROWS ONLY;"
```

Output:

```
  ACTOR_ID FIRST_NAME      LAST_NAME
---------- --------------- ---------------
         1 PENELOPE        GUINESS
         2 NICK            WAHLBERG
         3 ED              CHASE
         4 JENNIFER        DAVIS
         5 JOHNNY          LOLLOBRIGIDA
```

## JDBC

```
jdbc:oracle:thin:@//localhost:1521/SAKILA
user=sakila
password=p_ssW0rd
```

## Tables

| Table         | Row Count |
|---------------|-----------|
| actor         | 200       |
| address       | 603       |
| category      | 16        |
| city          | 600       |
| country       | 109       |
| customer      | 599       |
| film          | 1000      |
| film_actor    | 5462      |
| film_category | 1000      |
| inventory     | 4581      |
| language      | 6         |
| payment       | 16049     |
| rental        | 16044     |
| staff         | 2         |
| store         | 2         |

## Views

- `customer_list` — customer information with address details
- `staff_list` — staff information with address details
- `sales_by_store` — total sales grouped by store
- `sales_by_film_category` — total sales grouped by film category
- `film_list` — film information with actors (uses `LISTAGG` rather than the
  MySQL original's `GROUP_CONCAT`)

## Notes

- Stored procedures, functions, and triggers are not ported. The MySQL
  originals (`rewards_report`, `get_customer_balance`, `film_in_stock`, etc.)
  are MySQL-specific PL/SQL and out of scope for this image.
- The `film_text` table (a MySQL FULLTEXT helper populated by triggers) is
  omitted, matching the other `sakiladb/*` images.
- The views `actor_info` and `nicer_but_slower_film_list` are omitted — both
  rely on `GROUP_CONCAT` semantics and correlated subqueries that don't carry
  over cleanly to Oracle.
- The `picture` BLOB column is omitted from the `staff` table.
- The `location` GEOMETRY column is omitted from the `address` table.
- `film.special_features` is stored as a comma-separated `VARCHAR2(100)`
  rather than a `SET`/array, matching what other ports of Sakila do.
- Identity column high-water marks are realigned to `MAX(id)+1` after data
  load, so subsequent `INSERT`s without explicit ids will not collide.
