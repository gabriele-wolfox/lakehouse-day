-- Pattern 3: pgvector as the serving layer for lake-produced embeddings.
-- Run against database `lakedb`, after scripts/02-generate-embeddings.sh.

CREATE TABLE IF NOT EXISTS docs (
    doc_id    integer PRIMARY KEY,
    title     text NOT NULL,
    topic     text NOT NULL,
    embedding vector(8)
);

-- Same pg_duckdb bridge as pattern 2, but loading instead of joining: pull
-- the batch-produced embeddings straight out of the lake into Postgres.
-- pg_duckdb table functions return a single composite row value, so
-- columns are accessed with r['colname'] against the row alias.
--
-- pg_duckdb pushes `INSERT ... SELECT ... FROM <duckdb function>` down to
-- DuckDB's own executor, which doesn't understand pgvector's `vector` type
-- ("DuckDB does not support INSERTs into tables with column of unsupported
-- type"). So we stage into a plain double-precision-array column first
-- (a type DuckDB understands) and cast to vector(8) in a second, pure
-- Postgres INSERT that never touches DuckDB.
CREATE TEMP TABLE docs_staging (
    doc_id    integer,
    title     text,
    topic     text,
    embedding double precision[]
);

INSERT INTO docs_staging
SELECT r['doc_id']::integer, r['title']::text, r['topic']::text,
       r['embedding']::double precision[]
FROM read_parquet('s3://lakehouse/warehouse/embeddings/embeddings.parquet') r;

INSERT INTO docs (doc_id, title, topic, embedding)
SELECT doc_id, title, topic, embedding::vector(8)
FROM docs_staging
ON CONFLICT (doc_id) DO NOTHING;

DROP TABLE docs_staging;

CREATE INDEX IF NOT EXISTS docs_embedding_hnsw
    ON docs USING hnsw (embedding vector_cosine_ops);

-- "Find docs like 'Vector Search with pgvector'" -- should surface the
-- other 'ai' topic docs first, since embeddings are topic-seeded.
SELECT title, topic,
       embedding <=> (SELECT embedding FROM docs WHERE title = 'Vector Search with pgvector') AS distance
FROM docs
ORDER BY distance
LIMIT 5;

-- The payoff: millisecond-latency similarity search, no lake round-trip.
EXPLAIN (ANALYZE, BUFFERS)
SELECT title
FROM docs
ORDER BY embedding <=> (SELECT embedding FROM docs WHERE title = 'Vector Search with pgvector')
LIMIT 5;
