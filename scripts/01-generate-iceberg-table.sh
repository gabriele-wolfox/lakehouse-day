#!/usr/bin/env bash
# Simulates the batch/streaming side of the lakehouse: a Spark/Flink job
# writing an Iceberg table into the same RustFS bucket CNPG archives WAL to.
#
# Uses the `duckdb` CLI's iceberg extension to COPY straight to Iceberg
# format on S3 -- no catalog server, no ORM. Deliberately the same engine
# (DuckDB) that pg_duckdb embeds inside CloudNativePG for pattern 2, so the
# writer and the reader really are "just DuckDB" talking to the same bucket.
set -euo pipefail

: "${RUSTFS_ENDPOINT:=http://localhost:9000}"
: "${RUSTFS_ACCESS_KEY:?set RUSTFS_ACCESS_KEY}"
: "${RUSTFS_SECRET_KEY:?set RUSTFS_SECRET_KEY}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE_PATH="s3://lakehouse/warehouse/analytics/customer_events"
ENDPOINT_HOST="${RUSTFS_ENDPOINT#http://}"
ENDPOINT_HOST="${ENDPOINT_HOST#https://}"

command -v duckdb >/dev/null 2>&1 || {
  echo "duckdb CLI not found on PATH -- run scripts/00-preflight.sh first" >&2
  exit 1
}

SECRET_SQL="CREATE OR REPLACE SECRET rustfs (TYPE S3, KEY_ID '${RUSTFS_ACCESS_KEY}', SECRET '${RUSTFS_SECRET_KEY}', ENDPOINT '${ENDPOINT_HOST}', URL_STYLE 'path', USE_SSL false, REGION 'us-east-1');"

duckdb <<SQL
INSTALL httpfs; LOAD httpfs;
INSTALL iceberg; LOAD iceberg;
INSTALL avro; LOAD avro;
${SECRET_SQL}

-- 200 synthetic events across 51 customers, deterministic via hash() so
-- re-running this script produces the same table.
CREATE OR REPLACE TABLE customer_events AS
SELECT
    i                                                                                          AS event_id,
    (1000 + (hash(i) % 51)::BIGINT)                                                            AS customer_id,
    (['purchase', 'refund', 'signup', 'churn', 'support_ticket'])[1 + (hash(i * 7) % 5)::BIGINT] AS event_type,
    TIMESTAMP '2026-09-01 00:00:00' - ((hash(i * 13) % (60 * 24 * 30))::BIGINT * INTERVAL 1 MINUTE) AS event_ts,
    round((hash(i * 17) % 49500)::BIGINT / 100.0 + 5, 2)                                        AS amount
FROM range(1, 201) AS t(i);

COPY customer_events TO '${TABLE_PATH}' (FORMAT ICEBERG);
SQL

METADATA_LOCATION="$(duckdb -csv -noheader <<SQL | grep -E '\.metadata\.json$'
INSTALL httpfs; LOAD httpfs;
${SECRET_SQL}
SELECT file FROM glob('${TABLE_PATH}/metadata/*.metadata.json') ORDER BY file DESC LIMIT 1;
SQL
)"

echo "$METADATA_LOCATION" > "$DIR/.iceberg_metadata_location"
echo "Wrote 200-row Iceberg table to ${TABLE_PATH}"
echo "METADATA_LOCATION=${METADATA_LOCATION}"
