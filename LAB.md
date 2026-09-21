# Lab Walkthrough

Everything in `scripts/00-preflight.sh` must already be done (see README.md).
Below is what actually gets typed/shown against the lab cluster. Two
terminals are used: **A** for `kubectl`, **B** for an interactive `psql`
session.

## 1. Shared object storage

**Terminal A**

```bash
kubectl get objectstore rustfs-objectstore -o yaml | head -20
kubectl cnpg status pglake
```

Point at the `Continuous Backup status` line: WAL is archiving to
`s3://lakehouse/cnpg-backups/`.

Open the RustFS console to show the bucket itself:

```bash
kubectl port-forward svc/rustfs 9001:9001
```

Browse to `http://localhost:9001`, open bucket `lakehouse`. Show the two
prefixes side by side:

- `cnpg-backups/`: WAL segments and base backups CNPG just wrote
- `warehouse/analytics/customer_events/`: the Iceberg table from
  `scripts/01-generate-iceberg-table.sh`, written by DuckDB standing in for
  a Spark/Flink batch job

Talking point: same bucket, same IAM/policy boundary, same lifecycle rules,
same encryption-at-rest story. One storage layer serving both the
operational database and the lakehouse.

Ctrl-C the port-forward.

## 2. Foreign Data Wrappers: pg_duckdb reads the lake

**Terminal A**: run the scripted part first (secret + install + the raw
Iceberg scan):

```bash
kubectl cnpg psql pglake -- -d lakedb < sql/02-fdw-iceberg.sql
```

This prints: the 10 most recent Iceberg rows, then the `customers` table
being seeded, then **the payoff**: top 5 customers by purchase total,
joining the native Postgres `customers` table against the Iceberg
`customer_events` table in one query.

**Terminal B**: open this interactively and re-run just the join to inspect
it directly:

```bash
kubectl cnpg psql pglake -- -d lakedb
```

```sql
SELECT c.customer_name, c.segment, count(*) AS events, sum(e['amount']) AS total_amount
FROM iceberg_scan('<paste METADATA_LOCATION from scripts/.iceberg_metadata_location>') AS e
JOIN customers c ON c.customer_id = e['customer_id']
WHERE e['event_type'] = 'purchase'
GROUP BY c.customer_name, c.segment
ORDER BY total_amount DESC
LIMIT 5;
```

Talking point: no ETL job, no nightly copy into a staging table. The
"cold" Iceberg data and the "hot" Postgres table are joined by the
Postgres query planner in the same statement.

## 3. pgvector for embedding retrieval

**Terminal B** (same session):

```bash
\i sql/03-pgvector.sql
```

If `\i` can't see the file (it runs inside the pod via `kubectl exec`),
instead run from Terminal A:

```bash
kubectl cnpg psql pglake -- -d lakedb < sql/03-pgvector.sql
```

Point at:

- The `INSERT ... FROM read_parquet('s3://...')`: the embeddings that
  "Spark/Flink produced" land straight in the `docs` table via the same
  `pg_duckdb` bridge used in pattern 2.
- The similarity result: docs from the same topic as *"Vector Search with
  pgvector"* surface first.
- The `EXPLAIN (ANALYZE, BUFFERS)` at the bottom: call out the actual
  execution time against the HNSW index.

Talking point: this closes the loop; batch-produced embeddings, served at
millisecond latency, no separate vector database.

## Summary

One shared bucket, one set of policies (pattern 1). One query surface for
hot and cold data (pattern 2). One serving layer for lake-produced
embeddings (pattern 3). CloudNativePG isn't outside the Lakehouse: it's
the last mile in front of it.
