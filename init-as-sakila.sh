#!/bin/bash
# Runs the Sakila schema/data/finalize SQL as the APP_USER against FREEPDB1.
# gvenzl's run_custom_scripts() invokes us from /container-entrypoint-initdb.d/
# only after the APP_USER has been created.
#
# We intentionally do NOT drop these files into /container-entrypoint-initdb.d/
# directly: gvenzl runs *.sql there as SYSDBA against the CDB, but we want
# objects owned by the sakila app user inside FREEPDB1.

set -Eeuo pipefail

echo "CONTAINER: loading Sakila schema and data into FREEPDB1 as ${APP_USER}..."

sqlplus -L "${APP_USER}/${APP_USER_PASSWORD}@//localhost:1521/FREEPDB1" <<'EOF'
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

echo "CONTAINER: Sakila loaded. Shutting database down cleanly so the data"
echo "CONTAINER: directory layer can be committed in a consistent state."

# Graceful shutdown: ensures datafiles are quiesced before the Docker layer
# snapshot is taken. Without this, the OCI layer captures live datafiles and
# the resulting image needs instance recovery on first start.
sqlplus -L -S / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SHUTDOWN IMMEDIATE
EXIT
EOF

lsnrctl stop || true
