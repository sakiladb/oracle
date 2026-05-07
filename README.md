# sakiladb/oracle

Oracle Database 23ai docker image preloaded with the [Sakila](https://dev.mysql.com/doc/sakila/en/)
example database (by way of [jOOQ](https://www.jooq.org/sakila)).
See on [Docker Hub](https://hub.docker.com/r/sakiladb/oracle).

By default these are created:
- pluggable database: `FREEPDB1`
- username / password: `sakila` / `p_ssW0rd`
- schema (= app user): `sakila`

## Quick Start

```shell
docker run -p 1521:1521 -d sakiladb/oracle:latest
```

The image is built on top of [`gvenzl/oracle-free:slim-faststart`](https://hub.docker.com/r/gvenzl/oracle-free)
and ships with the data directory pre-populated, so the database is ready to
query within seconds of container start.

## Build Locally

```shell
python3 convert_data.py ../mysql/2-sakila-data.sql 2-oracle-sakila-data.sql
docker build -t sakiladb/oracle:latest .
```

## Ports

- `1521`: Oracle Net listener (TCP)

## Verify Installation

Using `sqlplus` from inside the container:

```shell
docker exec -it $(docker ps -q -f ancestor=sakiladb/oracle:latest) \
    sqlplus sakila/p_ssW0rd@//localhost:1521/FREEPDB1 \
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
jdbc:oracle:thin:@//localhost:1521/FREEPDB1
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
