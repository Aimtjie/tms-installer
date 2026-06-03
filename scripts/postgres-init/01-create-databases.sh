#!/bin/sh
# Mounted into /docker-entrypoint-initdb.d in the postgres container.
# Runs once on first boot to create ticketdb and keycloakdb.

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE ticketdb;
    CREATE DATABASE keycloakdb;
EOSQL
