#!/bin/bash
# Runs the Sakila schema/data/finalize SQL as the APP_USER against the
# SAKILA PDB (created by gvenzl's entrypoint via ORACLE_DATABASE=SAKILA),
# then drops the empty default FREEPDB1 PDB so the final image carries
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
@/sakila/2-oracle-sakila-data.sql
@/sakila/3-oracle-sakila-finalize.sql
EXIT
EOF

echo "CONTAINER: Sakila loaded. Dropping the empty FREEPDB1 PDB to slim the image."

# FREEPDB1 is created by the gvenzl base image as the default sample PDB.
# We don't use it (Sakila lives in SAKILA), so drop it to recover ~500 MB
# of system/sysaux/users/temp tablespaces from the final image. Must be
# CLOSED before DROP. INCLUDING DATAFILES removes the underlying files.
sqlplus -L -S / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER PLUGGABLE DATABASE FREEPDB1 CLOSE IMMEDIATE;
DROP PLUGGABLE DATABASE FREEPDB1 INCLUDING DATAFILES;
EXIT
EOF

echo "CONTAINER: FREEPDB1 dropped. Shutting database down cleanly so the"
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
