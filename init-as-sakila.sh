#!/bin/bash
# Runs the Sakila schema/data/finalize SQL as the APP_USER against the
# SAKILA PDB (created by gvenzl's entrypoint via ORACLE_DATABASE=SAKILA),
# then drops the empty default PDB (FREEPDB1 or XEPDB1) so the final image carries
# only the Sakila tablespaces.
#
# We intentionally do NOT drop the SQL files into /container-entrypoint-initdb.d/
# directly: gvenzl runs *.sql there as SYSDBA against the CDB, but we want
# objects owned by the sakila app user inside the SAKILA PDB.

set -Eeuo pipefail

PDB="${ORACLE_DATABASE:-SAKILA}"

echo "CONTAINER: loading Sakila schema and data into ${PDB} as ${APP_USER}..."

sqlplus -L "${APP_USER}/${APP_USER_PASSWORD}@//localhost:1521/${PDB}" <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
-- Disable substitution-variable scanning so '&' inside string literals is safe.
SET DEFINE OFF
SET ECHO ON
SET FEEDBACK ON
@/sakila/1-oracle-sakila-schema.sql
-- Quiet the data load. Echoing its ~46k rows (and a "rows created" line per
-- INSERT) overruns BuildKit's 2 MiB per-step log cap, which then clips
-- everything after it - including any error from the finalize row-count
-- tripwire. Errors here are still reported (ORA-, line, and offending text).
SET ECHO OFF
SET FEEDBACK OFF
PROMPT CONTAINER: loading Sakila data (echo off)...
@/sakila/2-oracle-sakila-data.sql
PROMPT CONTAINER: Sakila data loaded.
SET ECHO ON
SET FEEDBACK ON
@/sakila/3-oracle-sakila-finalize.sql
EXIT
EOF

echo "CONTAINER: Sakila loaded. Dropping the empty default PDB to slim the image."

# The gvenzl base creates a default sample PDB: FREEPDB1 on 23ai Free, XEPDB1
# on 21c XE. We don't use it (Sakila lives in SAKILA), so drop it to recover
# ~500 MB of system/sysaux/users/temp tablespaces from the final image. Rather
# than hard-code its name, drop every PDB that isn't ours or the seed. Must be
# CLOSED before DROP. INCLUDING DATAFILES removes the underlying files.
sqlplus -L -S / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET SERVEROUTPUT ON
BEGIN
  FOR p IN (SELECT name FROM v\$pdbs WHERE name NOT IN ('PDB\$SEED', '${PDB}')) LOOP
    DBMS_OUTPUT.PUT_LINE('CONTAINER: dropping PDB ' || p.name);
    EXECUTE IMMEDIATE 'ALTER PLUGGABLE DATABASE ' || p.name || ' CLOSE IMMEDIATE';
    EXECUTE IMMEDIATE 'DROP PLUGGABLE DATABASE ' || p.name || ' INCLUDING DATAFILES';
  END LOOP;
END;
/
EXIT
EOF

echo "CONTAINER: default PDB dropped. Shutting database down cleanly so the"
echo "CONTAINER: data directory layer can be committed in a consistent state."

# Graceful shutdown: ensures datafiles are quiesced before the Docker layer
# snapshot is taken. Without this, the OCI layer captures live datafiles and
# the resulting image needs instance recovery on first start.
sqlplus -L -S / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SHUTDOWN IMMEDIATE
EXIT
EOF

lsnrctl stop || true
