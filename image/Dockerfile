# Custom CloudNativePG operand image: adds pg_duckdb (github.com/duckdb/pg_duckdb)
# to the official CNPG PostgreSQL 17 image so the Cluster can read Iceberg/Parquet
# straight out of object storage (pattern 2) and load embeddings for pgvector
# (pattern 3).
#
# This copies the prebuilt pg_duckdb binaries out of the official
# pgduckdb/pgduckdb:17-main image instead of compiling pg_duckdb from source.
# Both that image and our CNPG base track postgres:17-bookworm, so the
# extension .so and its transitive shared-library dependencies are ABI
# compatible -- see the note in README.md.
ARG CNPG_BASE=ghcr.io/cloudnative-pg/postgresql:17-standard-bookworm
ARG PGDUCKDB_IMAGE=pgduckdb/pgduckdb:17-main

FROM ${PGDUCKDB_IMAGE} AS pgduckdb_prebuilt

FROM ${CNPG_BASE}
USER root

# pg_duckdb.so and libduckdb.so pull in libcurl4 (and its transitive deps:
# nghttp2, rtmp, ssh2, psl, brotli) which the CNPG base doesn't ship by
# default; everything else they need (libstdc++, libssl, libgssapi_krb5,
# libldap, liblz4, ...) is already present in the base image.
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=pgduckdb_prebuilt /usr/lib/postgresql/17/lib/pg_duckdb.so /usr/lib/postgresql/17/lib/pg_duckdb.so
COPY --from=pgduckdb_prebuilt /usr/lib/postgresql/17/lib/libduckdb.so /usr/lib/postgresql/17/lib/libduckdb.so
COPY --from=pgduckdb_prebuilt /usr/share/postgresql/17/extension/pg_duckdb.control /usr/share/postgresql/17/extension/pg_duckdb.control
COPY --from=pgduckdb_prebuilt /usr/share/postgresql/17/extension/pg_duckdb--*.sql /usr/share/postgresql/17/extension/

USER postgres
