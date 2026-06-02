#!/opt/document-pipeline/.venv/bin/python
import hashlib
import json
import os
import sys
import tempfile
import traceback
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import clickhouse_connect
from docx import Document
from minio import Minio
from openai import OpenAI
from pypdf import PdfReader


SUPPORTED_SUFFIXES = {".pdf", ".docx"}


@dataclass
class SourceObject:
    bucket: str
    object_key: str
    etag: str
    source_last_modified: datetime
    source_size: int
    content_type: str


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    return int(value) if value else default


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalize_etag(etag: str) -> str:
    return (etag or "").strip('"')


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def get_clickhouse_client():
    return clickhouse_connect.get_client(
        host=os.environ.get("CLICKHOUSE_HOST", "localhost"),
        port=env_int("CLICKHOUSE_PORT", 8123),
        username=os.environ.get("CLICKHOUSE_USER", "default"),
        password=os.environ.get("CLICKHOUSE_PASSWORD", ""),
        database=os.environ.get("CLICKHOUSE_DATABASE", os.environ.get("CLICKHOUSE_DB", "document_pipeline")),
    )


def get_minio_client():
    endpoint = os.environ.get("MINIO_ENDPOINT", "minio:9000")
    secure = os.environ.get("MINIO_SECURE", "false").lower() == "true"
    return Minio(
        endpoint,
        access_key=os.environ["MINIO_ACCESS_KEY"],
        secret_key=os.environ["MINIO_SECRET_KEY"],
        secure=secure,
    )


def ensure_bucket(client: Minio, bucket: str) -> None:
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)


def list_supported_objects(client: Minio, bucket: str, prefix: str) -> tuple[list[SourceObject], int]:
    ensure_bucket(client, bucket)
    scanned_count = 0
    supported: list[SourceObject] = []
    for item in client.list_objects(bucket, prefix=prefix or "", recursive=True):
        scanned_count += 1
        suffix = Path(item.object_name).suffix.lower()
        if suffix not in SUPPORTED_SUFFIXES:
            continue
        stat = client.stat_object(bucket, item.object_name)
        supported.append(
            SourceObject(
                bucket=bucket,
                object_key=item.object_name,
                etag=normalize_etag(stat.etag or item.etag or ""),
                source_last_modified=(stat.last_modified or item.last_modified).astimezone(timezone.utc),
                source_size=stat.size or item.size or 0,
                content_type=stat.content_type or "",
            )
        )
    supported.sort(key=lambda obj: (obj.source_last_modified, obj.object_key))
    return supported, scanned_count


def get_ingestion_record(ch, source: SourceObject):
    rows = ch.query(
        """
        SELECT status, attempt_count
        FROM document_ingestions FINAL
        WHERE bucket = %(bucket)s AND object_key = %(object_key)s AND etag = %(etag)s
        LIMIT 1
        """,
        parameters={"bucket": source.bucket, "object_key": source.object_key, "etag": source.etag},
    ).result_rows
    return rows[0] if rows else None


def choose_candidates(ch, objects: list[SourceObject], max_docs: int, max_attempts: int) -> tuple[list[SourceObject], int]:
    candidates: list[SourceObject] = []
    skipped_count = 0
    for source in objects:
        record = get_ingestion_record(ch, source)
        if record is None:
            candidates.append(source)
        else:
            status, attempt_count = record
            if status == "failed" and int(attempt_count) < max_attempts:
                candidates.append(source)
            else:
                skipped_count += 1
        if len(candidates) >= max_docs:
            break
    skipped_count += max(0, len(objects) - len(candidates) - skipped_count)
    return candidates, skipped_count


def download_object(client: Minio, source: SourceObject) -> str:
    suffix = Path(source.object_key).suffix.lower()
    fd, path = tempfile.mkstemp(suffix=suffix)
    os.close(fd)
    client.fget_object(source.bucket, source.object_key, path)
    return path


def extract_pdf(path: str) -> str:
    reader = PdfReader(path)
    return "\n\n".join((page.extract_text() or "") for page in reader.pages).strip()


def extract_docx(path: str) -> str:
    doc = Document(path)
    return "\n".join(paragraph.text for paragraph in doc.paragraphs).strip()


def extract_text(path: str, object_key: str) -> str:
    suffix = Path(object_key).suffix.lower()
    if suffix == ".pdf":
        return extract_pdf(path)
    if suffix == ".docx":
        return extract_docx(path)
    raise ValueError(f"Unsupported source document type: {suffix}")


def chunk_text(text: str, chunk_size: int, chunk_overlap: int) -> list[tuple[int, int, str]]:
    if not text:
        return []
    if chunk_overlap >= chunk_size:
        raise ValueError("CHUNK_OVERLAP must be smaller than CHUNK_SIZE")
    chunks = []
    start = 0
    while start < len(text):
        end = min(len(text), start + chunk_size)
        chunk = text[start:end].strip()
        if chunk:
            chunks.append((start, end, chunk))
        if end >= len(text):
            break
        start = end - chunk_overlap
    return chunks


def embed_chunks(openai_client: OpenAI, model: str, chunks: list[str]) -> list[list[float]]:
    if not chunks:
        return []
    response = openai_client.embeddings.create(model=model, input=chunks)
    return [item.embedding for item in response.data]


def record_version(status: str, attempt_count: int) -> int:
    state_order = {"processing": 1, "completed": 2, "failed": 3}
    return attempt_count * 10 + state_order[status]


def insert_ingestion(ch, source: SourceObject, document_version_id: str, status: str, attempt_count: int, last_error: str, chunk_count: int, completed_at):
    now = utc_now()
    ch.insert(
        "document_ingestions",
        [
            [
                source.bucket,
                source.object_key,
                source.etag,
                document_version_id,
                source.source_last_modified,
                source.source_size,
                source.content_type,
                status,
                attempt_count,
                last_error,
                chunk_count,
                record_version(status, attempt_count),
                now,
                now,
                completed_at,
            ]
        ],
        column_names=[
            "bucket",
            "object_key",
            "etag",
            "document_version_id",
            "source_last_modified",
            "source_size",
            "content_type",
            "status",
            "attempt_count",
            "last_error",
            "chunk_count",
            "record_version",
            "created_at",
            "updated_at",
            "completed_at",
        ],
    )


def delete_chunks(ch, document_version_id: str) -> None:
    ch.command(
        "ALTER TABLE document_chunks DELETE WHERE document_version_id = %(document_version_id)s SETTINGS mutations_sync = 1",
        parameters={"document_version_id": document_version_id},
    )


def process_source(ch, minio_client: Minio, openai_client: OpenAI, source: SourceObject, attempt_count: int, config: dict) -> int:
    document_version_id = sha256_hex(f"{source.bucket}\0{source.object_key}\0{source.etag}")
    insert_ingestion(ch, source, document_version_id, "processing", attempt_count, "", 0, None)
    delete_chunks(ch, document_version_id)

    path = download_object(minio_client, source)
    try:
        text = extract_text(path, source.object_key)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass

    chunks = chunk_text(text, config["chunk_size"], config["chunk_overlap"])
    chunk_texts = [chunk for _, _, chunk in chunks]
    embeddings = embed_chunks(openai_client, config["embedding_model"], chunk_texts)
    if embeddings and len(embeddings[0]) != config["embedding_dimension"]:
        raise ValueError(
            f"Embedding dimension mismatch: expected {config['embedding_dimension']}, got {len(embeddings[0])}"
        )

    rows = []
    for index, ((start, end, chunk), embedding) in enumerate(zip(chunks, embeddings)):
        chunk_text_hash = sha256_hex(chunk)
        chunk_id = sha256_hex(f"{document_version_id}\0{index}\0{chunk_text_hash}")
        rows.append(
            [
                chunk_id,
                document_version_id,
                source.bucket,
                source.object_key,
                source.etag,
                index,
                start,
                end,
                chunk,
                chunk_text_hash,
                embedding,
                config["embedding_model"],
                utc_now(),
            ]
        )
    if rows:
        ch.insert(
            "document_chunks",
            rows,
            column_names=[
                "chunk_id",
                "document_version_id",
                "bucket",
                "object_key",
                "etag",
                "chunk_index",
                "chunk_start",
                "chunk_end",
                "chunk_text",
                "chunk_text_hash",
                "embedding",
                "embedding_model",
                "created_at",
            ],
        )
    insert_ingestion(ch, source, document_version_id, "completed", attempt_count, "", len(rows), utc_now())
    return len(rows)


def run():
    started_at = utc_now()
    run_id = str(uuid.uuid4())
    config = {
        "bucket": os.environ.get("MINIO_BUCKET", "documents"),
        "prefix": os.environ.get("MINIO_PREFIX", ""),
        "chunk_size": env_int("CHUNK_SIZE", 1000),
        "chunk_overlap": env_int("CHUNK_OVERLAP", 200),
        "embedding_model": os.environ.get("EMBEDDING_MODEL", "text-embedding-3-small"),
        "embedding_dimension": env_int("EMBEDDING_DIMENSION", 1536),
        "max_documents_per_run": env_int("MAX_DOCUMENTS_PER_RUN", 10),
        "max_attempts": env_int("MAX_ATTEMPTS", 3),
    }
    scanned_count = processed_count = skipped_count = failed_count = 0
    error_message = ""
    status = "completed"
    try:
        ch = get_clickhouse_client()
        minio_client = get_minio_client()
        openai_client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])

        objects, scanned_count = list_supported_objects(minio_client, config["bucket"], config["prefix"])
        candidates, skipped_count = choose_candidates(
            ch, objects, config["max_documents_per_run"], config["max_attempts"]
        )

        for source in candidates:
            record = get_ingestion_record(ch, source)
            attempt_count = int(record[1]) + 1 if record else 1
            document_version_id = sha256_hex(f"{source.bucket}\0{source.object_key}\0{source.etag}")
            try:
                process_source(ch, minio_client, openai_client, source, attempt_count, config)
                processed_count += 1
            except Exception as exc:
                failed_count += 1
                status = "partial_failed"
                message = str(exc)[:2000]
                print(traceback.format_exc(), file=sys.stderr)
                insert_ingestion(ch, source, document_version_id, "failed", attempt_count, message, 0, None)
        if failed_count and processed_count == 0:
            status = "failed"
    except Exception as exc:
        status = "failed"
        error_message = str(exc)[:2000]
        print(traceback.format_exc(), file=sys.stderr)

    finished_at = utc_now()
    print(
        json.dumps(
            {
                "run_id": run_id,
                "started_at": iso(started_at),
                "finished_at": iso(finished_at),
                "status": status,
                "scanned_count": scanned_count,
                "processed_count": processed_count,
                "skipped_count": skipped_count,
                "failed_count": failed_count,
                "error_message": error_message,
            },
            ensure_ascii=True,
        ),
        flush=True,
    )


if __name__ == "__main__":
    run()
