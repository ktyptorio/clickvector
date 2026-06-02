CREATE DATABASE IF NOT EXISTS document_pipeline;

USE document_pipeline;

SET allow_experimental_refreshable_materialized_view = 1;
SET allow_experimental_vector_similarity_index = 1;

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
    created_at DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    updated_at DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
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
    created_at DateTime64(3, 'UTC') DEFAULT now64(3, 'UTC'),
    INDEX embedding_hnsw embedding TYPE vector_similarity('hnsw', 'cosineDistance', 1536) GRANULARITY 100000000
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

CREATE MATERIALIZED VIEW IF NOT EXISTS ingestion_runs_mv
REFRESH EVERY 30 SECOND
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
    'ingest_runner.py',
    'JSONEachRow',
    'run_id String, started_at DateTime64(3, ''UTC''), finished_at DateTime64(3, ''UTC''), status Enum8(''completed'' = 1, ''partial_failed'' = 2, ''failed'' = 3), scanned_count UInt32, processed_count UInt32, skipped_count UInt32, failed_count UInt32, error_message String'
);
