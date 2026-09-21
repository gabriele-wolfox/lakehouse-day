#!/usr/bin/env bash
# Simulates the embedding side of the lakehouse: a Spark/Flink job turning
# unstructured docs into vectors and dropping a Parquet file into RustFS.
#
# No real embedding model on purpose -- the vector for each doc is seeded
# from its topic (not a real model), so docs in the same topic cluster
# together for cosine similarity. The point is the pipeline shape, not the
# model.
set -euo pipefail

: "${RUSTFS_ENDPOINT:=http://localhost:9000}"
: "${RUSTFS_ACCESS_KEY:?set RUSTFS_ACCESS_KEY}"
: "${RUSTFS_SECRET_KEY:?set RUSTFS_SECRET_KEY}"

OUTPUT_PATH="s3://lakehouse/warehouse/embeddings/embeddings.parquet"
ENDPOINT_HOST="${RUSTFS_ENDPOINT#http://}"
ENDPOINT_HOST="${ENDPOINT_HOST#https://}"
DIM=8

command -v duckdb >/dev/null 2>&1 || {
  echo "duckdb CLI not found on PATH -- run scripts/00-preflight.sh first" >&2
  exit 1
}

duckdb <<SQL
INSTALL httpfs; LOAD httpfs;

CREATE OR REPLACE SECRET rustfs (
    TYPE S3,
    KEY_ID '${RUSTFS_ACCESS_KEY}',
    SECRET '${RUSTFS_SECRET_KEY}',
    ENDPOINT '${ENDPOINT_HOST}',
    URL_STYLE 'path',
    USE_SSL false,
    REGION 'us-east-1'
);

CREATE OR REPLACE TABLE docs (doc_id INTEGER, title VARCHAR, topic VARCHAR);
INSERT INTO docs VALUES
    (1,  'Postgres Under the Hood',        'internals'),
    (2,  'CloudNativePG Architecture',     'operations'),
    (3,  'Iceberg Table Format',           'lakehouse'),
    (4,  'Vector Search with pgvector',    'ai'),
    (5,  'Kubernetes Storage Classes',     'operations'),
    (6,  'Streaming Replication Explained','internals'),
    (7,  'Apache Spark Batch Jobs',        'lakehouse'),
    (8,  'Embedding Models 101',           'ai'),
    (9,  'WAL Archiving Strategies',       'operations'),
    (10, 'HNSW Index Internals',           'ai'),
    (11, 'Delta Lake vs Iceberg',          'lakehouse'),
    (12, 'Backups with Barman Cloud',      'operations');

COPY (
    SELECT
        doc_id,
        title,
        topic,
        list_transform(
            range(0, ${DIM}),
            j -> ((hash(topic || j::VARCHAR) % 2000)::BIGINT - 1000) / 1000.0
        ) AS embedding
    FROM docs
) TO '${OUTPUT_PATH}' (FORMAT PARQUET);
SQL

echo "Wrote 12 embeddings (dim=${DIM}) to ${OUTPUT_PATH}"
