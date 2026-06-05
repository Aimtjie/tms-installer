#!/bin/sh
# Mounted into /docker-entrypoint-initdb.d in the postgres container.
# Runs once, the first time the data directory is initialised — i.e. on first
# `docker compose up` after `docker compose down -v` (or on a fresh checkout).
# Subsequent boots skip this entirely because the data volume already exists.
#
# Creates the two logical databases the app and Keycloak each own. Both live in
# the same postgres instance to keep the compose footprint small; production
# k8s splits Keycloak onto its own cluster (k8s/helm/keycloak-values.yaml).

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE ticketdb;
    CREATE DATABASE keycloakdb;
EOSQL
