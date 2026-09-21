# Bridging Worlds: CloudNativePG as the Serving Layer for Modern Lakehouse Architectures

Public lab for Lakehouse Day 2026: a hands-on companion for anyone who
wants to reproduce the three patterns themselves. It runs entirely on a
local `kind` cluster: no hosted/online environment, nothing to sign up for.
Run the pre-flight steps below, then follow `LAB.md`.

## The three patterns

| # | Pattern | What it shows |
|:-:|:--------|:---------------|
| 1 | **Shared object storage** | A CloudNativePG `Cluster` archives WAL/backups and an Iceberg table (written by a "batch job") land in the *same* S3-compatible bucket: one storage layer, one set of policies. |
| 2 | **Foreign Data Wrappers** | `pg_duckdb` inside CloudNativePG reads the Iceberg table straight from object storage and joins it, in one SQL query, with a native "hot" Postgres table: no ETL. |
| 3 | **pgvector for retrieval** | Embeddings "produced by Spark/Flink" (simulated) are pulled from the lake into a `pgvector` table and served with an HNSW index at millisecond latency. |

Storage layer is [RustFS](https://github.com/rustfs/rustfs) (S3-compatible,
Apache-2.0). Table format is Apache Iceberg, written and read with
the `duckdb` CLI / [`pg_duckdb`](https://github.com/duckdb/pg_duckdb): no
Python anywhere in this repo, just bash and SQL. `pg_duckdb` is added to a
custom CloudNativePG operand image by copying the prebuilt extension files
out of the official `pgduckdb/pgduckdb:17-main` image (no compiling from
source; see `image/Dockerfile`).

**Gotcha:** `pg_duckdb` table functions
like `iceberg_scan()` and `read_parquet()` return each row as a single
composite value, not individual named columns. Alias the function and pull
fields out with `row['colname']` (e.g. `r['customer_id']`), not plain
`customer_id`; `sql/02-fdw-iceberg.sql.tmpl` and `sql/03-pgvector.sql` both
already do this.

## Repo layout

```
manifests/   CNPG Cluster, ObjectStore, Database CRDs, RustFS Deployment/Service
image/       Dockerfile for the custom operand image (CNPG postgres + pg_duckdb)
sql/         The SQL used during the lab
scripts/     Pre-flight automation: kind cluster, operator, image build, data generation
LAB.md       Lab walkthrough: commands and talking points
```

## Prerequisites

- `docker`, `kind`, `kubectl`, the [`cnpg` kubectl plugin](https://cloudnative-pg.io/documentation/current/kubectl-plugin/)
- `aws` CLI (only used to create the RustFS bucket through a local port-forward)
- The `duckdb` CLI is installed automatically by the pre-flight script if missing
- No C++ toolchain or heavy disk/CPU budget needed: `image/Dockerfile` only pulls two small prebuilt images and copies files, it doesn't compile anything

## Pre-flight

```bash
./scripts/00-preflight.sh
```

This will (idempotently):

1. Create a local `kind` cluster
2. Install `cert-manager`, the CloudNativePG operator, and the `barman-cloud` CNPG-I plugin (latest releases, fetched dynamically)
3. Build `image/Dockerfile` (CNPG operand + prebuilt `pg_duckdb` binaries copied from `pgduckdb/pgduckdb:17-main`) and load it into `kind`: this is just pulling two small images and copying files, no compiling, should take well under a minute after the images are cached locally
4. Deploy RustFS, create the `lakehouse` bucket
5. Apply the `ObjectStore`, `Cluster`, and `Database` manifests, wait for the cluster to reach `Cluster in healthy state`
6. Run `scripts/01-generate-iceberg-table.sh`: writes a small Iceberg table (simulating a Spark/Flink batch job) into RustFS via `duckdb`'s `COPY ... TO ... (FORMAT ICEBERG)`
7. Run `scripts/02-generate-embeddings.sh`: writes a Parquet file of synthetic, topic-clustered embeddings into RustFS (simulating an embedding pipeline)
8. Render `sql/02-fdw-iceberg.sql` with the real Iceberg metadata location and RustFS credentials

**Known rough edges**: here's what's actually been exercised end-to-end and
what's still worth double-checking:

- **Confirmed working:** `duckdb`'s Iceberg extension write path (`COPY ...
  TO ... (FORMAT ICEBERG)`, used in `scripts/01-generate-iceberg-table.sh`)
  is marked **experimental** upstream, but it has been verified end-to-end
  against RustFS: it writes valid metadata/manifests/Parquet straight to
  S3-compatible storage, and `iceberg_scan()` reads it back correctly.
- **Still the main thing to re-verify:** `image/Dockerfile`
  copies `pg_duckdb`'s compiled `.so` and its `libduckdb.so` dependency out
  of the official `pgduckdb/pgduckdb:17-main` image onto the CNPG operand
  base. Both images track `postgres:17-bookworm`, so this has worked in
  testing, but it's an ABI assumption rather than a guarantee: if
  `pg_duckdb` fails to load (check the `pglake-1` pod logs for a
  `shared_preload_libraries` error), the fallback is to flip which image is
  primary: start `FROM pgduckdb/pgduckdb:17-main` and `apt-get install
  postgresql-17-pgvector` into it instead (that image already has the PGDG
  apt repo configured).
- `pg_duckdb` table functions return composite rows, not plain columns:
  see the gotcha note above. New queries need the `row['colname']` accessor
  too.
- `pg_duckdb` pushes `INSERT ... SELECT ... FROM <duckdb function>` down to
  DuckDB's own executor, which doesn't understand pgvector's `vector` type
  ("DuckDB does not support INSERTs into tables with column of unsupported
  type"). `sql/03-pgvector.sql` works around this by staging into a plain
  `double precision[]` temp table first, then casting to `vector(8)` in a
  second, pure-Postgres `INSERT` that never touches DuckDB.

Run `./scripts/99-cleanup.sh` to tear the `kind` cluster down afterwards.

## Running the lab

Follow [`LAB.md`](LAB.md): copy-paste `kubectl`/`psql` commands to run the
three patterns yourself.
