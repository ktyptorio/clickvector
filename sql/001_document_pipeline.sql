-- ClickHouse schema skeleton for the MinIO -> executable runner -> vector index pipeline.
-- Review syntax against the deployed ClickHouse version before applying.
--
-- Depending on the ClickHouse version, these may be required before creating
-- refreshable materialized views or vector similarity indexes:
-- SET allow_experimental_refreshable_materialized_view = 1;
-- SET allow_experimental_vector_similarity_index = 1;

CREATE DATABASE IF NOT EXISTS document_pipeline;

USE document_pipeline;

CREATE TABLE IF NOT EXISTS document_ingestions
(
    bucket String,
    object_key String,
    etag String,
    document_version_id String,
    source_last_modified DateTime64(3, 'UTC'),
    source_size UInt64,
    content_type LowCardinality(String),
    status Enum8('processing' = 1, 'completed' = 2, 'failed' = 3),
    attempt_count UInt16,
    last_error String,
    chunk_count UInt32,
    record_version UInt64,
    created_at DateTime64(3, 'UTC'),
    updated_at DateTime64(3, 'UTC'),
    completed_at Nullable(DateTime64(3, 'UTC'))
)
ENGINE = ReplacingMergeTree(record_version)
ORDER BY (bucket, object_key, etag);

CREATE TABLE IF NOT EXISTS document_chunks
(
    chunk_id String,
    document_version_id String,
    bucket String,
    object_key String,
    etag String,
    chunk_index UInt32,
    chunk_start UInt64,
    chunk_end UInt64,
    chunk_text String,
    chunk_text_hash String,
    embedding Array(Float32),
    embedding_model LowCardinality(String),
    created_at DateTime64(3, 'UTC'),
    INDEX embedding_hnsw embedding TYPE vector_similarity('hnsw', 'cosineDistance', 1536, 'bf16', 64, 512)
)
ENGINE = MergeTree
ORDER BY (bucket, object_key, etag, chunk_index);

CREATE TABLE IF NOT EXISTS ingestion_runs
(
    run_id String,
    started_at DateTime64(3, 'UTC'),
    finished_at DateTime64(3, 'UTC'),
    status Enum8('completed' = 1, 'partial_failed' = 2, 'failed' = 3),
    scanned_count UInt32,
    processed_count UInt32,
    skipped_count UInt32,
    failed_count UInt32,
    error_message String
)
ENGINE = MergeTree
ORDER BY (started_at, run_id);

-- APPEND keeps one audit row per run instead of replacing the target table.
-- The executable must emit JSONEachRow matching ingestion_runs.
-- Replace <bucket> and <prefix> before applying. Secrets remain environment variables.
CREATE MATERIALIZED VIEW IF NOT EXISTS ingestion_runs_mv
REFRESH EVERY 1 MINUTE
APPEND TO ingestion_runs
AS
SELECT
    run_id,
    started_at,
    finished_at,
    status,
    scanned_count,
    processed_count,
    skipped_count,
    failed_count,
    error_message
FROM executable(
    '/opt/document-pipeline/.venv/bin/python /opt/document-pipeline/ingest_runner.py --bucket <bucket> --prefix <prefix> --chunk-size 1000 --chunk-overlap 200 --embedding-model text-embedding-3-small --embedding-dimension 1536 --max-documents-per-run 10 --max-attempts 3',
    'JSONEachRow',
    'run_id String, started_at DateTime64(3, ''UTC''), finished_at DateTime64(3, ''UTC''), status Enum8(''completed'' = 1, ''partial_failed'' = 2, ''failed'' = 3), scanned_count UInt32, processed_count UInt32, skipped_count UInt32, failed_count UInt32, error_message String'
);

-- Retrieval skeleton: latest completed version per bucket/object_key, then cosine search.
-- Replace <query_embedding> with a 1536-value Array(Float32).
--
-- WITH
--     <query_embedding> AS query_embedding,
--     latest_versions AS
--     (
--         SELECT
--             bucket,
--             object_key,
--             argMax(document_version_id, (source_last_modified, completed_at, etag)) AS document_version_id
--         FROM document_ingestions
--         WHERE status = 'completed'
--         GROUP BY
--             bucket,
--             object_key
--     )
-- SELECT
--     c.bucket,
--     c.object_key,
--     c.etag,
--     c.chunk_index,
--     c.chunk_text,
--     cosineDistance(c.embedding, query_embedding) AS distance
-- FROM document_chunks AS c
-- INNER JOIN latest_versions AS lv
--     ON c.document_version_id = lv.document_version_id
-- ORDER BY distance ASC
-- LIMIT 10;
