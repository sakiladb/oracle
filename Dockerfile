# Multi-stage build: bake the Sakila schema+data into the Oracle data directory
# at build time, so users get a ready-to-query DB within seconds of `docker run`.
#
# Pattern mirrors postgres/Dockerfile and clickhouse/Dockerfile in this org.

FROM gvenzl/oracle-free:slim-faststart AS builder

ENV ORACLE_PASSWORD=p_ssW0rd \
    APP_USER=sakila \
    APP_USER_PASSWORD=p_ssW0rd

# SQL files live outside /container-entrypoint-initdb.d/ because gvenzl's
# initdb runner executes *.sql there as SYSDBA against the CDB. Our schema
# and data must be owned by the sakila app user inside FREEPDB1, so the
# init-as-sakila.sh shim opens its own sqlplus session as APP_USER.
COPY --chown=oracle:oinstall ./1-oracle-sakila-schema.sql   /sakila/
COPY --chown=oracle:oinstall ./2-oracle-sakila-data.sql     /sakila/
COPY --chown=oracle:oinstall ./3-oracle-sakila-finalize.sql /sakila/
COPY --chown=oracle:oinstall --chmod=755 ./init-as-sakila.sh \
     /container-entrypoint-initdb.d/01-init-as-sakila.sh

# --nowait makes the entrypoint exit after init scripts complete (instead of
# tail -f'ing alert.log). The init script itself does SHUTDOWN IMMEDIATE so
# the data directory is quiesced before the layer is committed.
RUN /opt/oracle/container-entrypoint.sh --nowait

# ---------------------------------------------------------------------------
FROM gvenzl/oracle-free:slim-faststart

# Replace the empty seed data directory with our pre-loaded one. The presence
# of /opt/oracle/oradata/dbconfig/FREE/ tells gvenzl's entrypoint that the
# DB is already initialized, so it skips create_dbconfig() and starts straight
# into the pre-loaded database.
RUN rm -rf /opt/oracle/oradata
COPY --chown=oracle:oinstall --from=builder /opt/oracle/oradata /opt/oracle/oradata

EXPOSE 1521
# ENTRYPOINT and CMD inherit from the base image.
