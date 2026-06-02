import hashlib
import io
import os
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import clickhouse_connect
import pymysql
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Cookie, Depends, FastAPI, File, HTTPException, Query, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from minio import Minio
from openai import OpenAI
from pydantic import BaseModel, EmailStr, Field


SESSION_COOKIE = "cv_session"
SESSION_TTL_SECONDS = 3600
MAX_UPLOAD_BYTES = 25 * 1024 * 1024
SUPPORTED_EXTENSIONS = {".pdf", ".docx"}
SUPPORTED_TYPES = {
    "application/pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
}


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def db() -> pymysql.connections.Connection:
    return pymysql.connect(
        host=os.getenv("MYSQL_HOST", "mysql"),
        port=int(os.getenv("MYSQL_PORT", "3306")),
        user=os.getenv("MYSQL_USER", "clickvector"),
        password=os.getenv("MYSQL_PASSWORD", "clickvector"),
        database=os.getenv("MYSQL_DATABASE", "clickvector"),
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=False,
    )


def ch():
    return clickhouse_connect.get_client(
        host=os.getenv("CLICKHOUSE_HOST", "clickhouse"),
        port=int(os.getenv("CLICKHOUSE_PORT", "8123")),
        username=os.getenv("CLICKHOUSE_USER", "default"),
        password=os.getenv("CLICKHOUSE_PASSWORD", "clickhouse"),
        database=os.getenv("CLICKHOUSE_DATABASE", "document_pipeline"),
    )


def minio_client() -> Minio:
    return Minio(
        os.getenv("MINIO_ENDPOINT", "minio:9000"),
        access_key=os.getenv("MINIO_ACCESS_KEY", "minioadmin"),
        secret_key=os.getenv("MINIO_SECRET_KEY", "minioadmin"),
        secure=os.getenv("MINIO_SECURE", "false").lower() == "true",
    )


def ensure_bucket(client: Minio) -> str:
    bucket = os.getenv("MINIO_BUCKET", "documents")
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)
    return bucket


def normalize_email(email: str) -> str:
    return email.strip().lower()


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def sanitize_filename(filename: str) -> str:
    name = Path(filename or "document").name.strip().replace("\x00", "")
    name = re.sub(r"[^A-Za-z0-9._ -]+", "_", name).strip(" .")
    return name or "document"


def stable_mock_embedding(text: str, dim: int = 1536) -> list[float]:
    seed = hashlib.sha256(text.encode("utf-8")).digest()
    values = []
    for i in range(dim):
        b = seed[i % len(seed)]
        values.append(((b / 255.0) * 2.0) - 1.0)
    return values


def embed_query(text: str) -> list[float]:
    if os.getenv("MOCK_EMBEDDINGS", "false").lower() == "true":
        return stable_mock_embedding(text, int(os.getenv("EMBEDDING_DIMENSION", "1536")))
    client = OpenAI(api_key=os.environ["OPENAI_API_KEY"])
    model = os.getenv("EMBEDDING_MODEL", "text-embedding-3-small")
    return client.embeddings.create(model=model, input=text).data[0].embedding


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    display_name: str | None = Field(default=None, min_length=1, max_length=120)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class RenameDocumentRequest(BaseModel):
    display_name: str = Field(min_length=1, max_length=255)


class QueryRequest(BaseModel):
    query: str = Field(min_length=1, max_length=2000)
    top_k: int = Field(default=10, ge=1, le=50)


def error(status: int, code: str, message: str, details: dict[str, Any] | None = None) -> HTTPException:
    return HTTPException(status_code=status, detail={"error": {"code": code, "message": message, "details": details or {}}})


def row_to_user(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "email": row["email"],
        "display_name": row["display_name"],
        "created_at": row["created_at"].replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def row_to_document(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": row["id"],
        "display_name": row["display_name"],
        "original_filename": row["original_filename"],
        "content_type": row["content_type"],
        "size_bytes": row["size_bytes"],
        "readiness": row["readiness"],
        "readiness_error": row["readiness_error"],
        "chunk_count": row["chunk_count"],
        "created_at": row["created_at"].replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z"),
        "updated_at": row["updated_at"].replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z"),
        "download_url": f"/api/documents/{row['id']}/download",
    }


def migrate() -> None:
    ddl = [
        """
        CREATE TABLE IF NOT EXISTS users (
            id CHAR(36) PRIMARY KEY,
            email VARCHAR(255) NOT NULL UNIQUE,
            display_name VARCHAR(120) NULL,
            password_hash VARCHAR(255) NOT NULL,
            created_at DATETIME(6) NOT NULL,
            updated_at DATETIME(6) NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id CHAR(36) PRIMARY KEY,
            user_id CHAR(36) NOT NULL,
            token_hash CHAR(64) NOT NULL UNIQUE,
            created_at DATETIME(6) NOT NULL,
            expires_at DATETIME(6) NOT NULL,
            revoked_at DATETIME(6) NULL,
            INDEX idx_sessions_token_hash (token_hash),
            INDEX idx_sessions_user_id (user_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS managed_documents (
            id CHAR(36) PRIMARY KEY,
            user_id CHAR(36) NOT NULL,
            display_name VARCHAR(255) NOT NULL,
            display_name_overridden BOOLEAN NOT NULL DEFAULT FALSE,
            original_filename VARCHAR(255) NOT NULL,
            latest_object_key TEXT NULL,
            latest_etag VARCHAR(128) NULL,
            content_type VARCHAR(255) NOT NULL,
            size_bytes BIGINT UNSIGNED NOT NULL DEFAULT 0,
            readiness ENUM('uploading','processing','ready','failed','archived') NOT NULL,
            readiness_error TEXT NULL,
            chunk_count INT UNSIGNED NOT NULL DEFAULT 0,
            created_at DATETIME(6) NOT NULL,
            updated_at DATETIME(6) NOT NULL,
            archived_at DATETIME(6) NULL,
            INDEX idx_documents_user_updated (user_id, updated_at),
            INDEX idx_documents_user_readiness (user_id, readiness)
        )
        """,
    ]
    with db() as conn:
        with conn.cursor() as cur:
            for statement in ddl:
                cur.execute(statement)
        conn.commit()


app = FastAPI(title="ClickVector API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[os.getenv("FRONTEND_ORIGIN", "http://localhost:5173")],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
ph = PasswordHasher()


@app.on_event("startup")
def startup() -> None:
    migrate()


async def current_user(cv_session: str | None = Cookie(default=None)) -> dict[str, Any]:
    if not cv_session:
        raise error(401, "unauthenticated", "Authentication is required.")
    token_hash = hash_token(cv_session)
    now = utc_now().replace(tzinfo=None)
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT u.*
            FROM sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = %s AND s.revoked_at IS NULL AND s.expires_at > %s
            LIMIT 1
            """,
            (token_hash, now),
        )
        row = cur.fetchone()
    if not row:
        raise error(401, "unauthenticated", "Authentication is required.")
    return row


def set_session_cookie(response: Response, user_id: str) -> str:
    raw = secrets.token_urlsafe(32)
    now = utc_now().replace(tzinfo=None)
    expires_at = now + timedelta(seconds=SESSION_TTL_SECONDS)
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at) VALUES (%s,%s,%s,%s,%s)",
            (str(uuid.uuid4()), user_id, hash_token(raw), now, expires_at),
        )
        conn.commit()
    response.set_cookie(
        SESSION_COOKIE,
        raw,
        max_age=SESSION_TTL_SECONDS,
        httponly=True,
        secure=os.getenv("COOKIE_SECURE", "false").lower() == "true",
        samesite="lax",
        path="/",
    )
    return raw


@app.get("/api/health")
def health() -> dict[str, Any]:
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1 AS ok")
        ok = cur.fetchone()["ok"]
    return {"ok": ok == 1}


@app.post("/api/auth/register", status_code=201)
def register(payload: RegisterRequest, response: Response) -> dict[str, Any]:
    email = normalize_email(payload.email)
    now = utc_now().replace(tzinfo=None)
    user_id = str(uuid.uuid4())
    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO users (id,email,display_name,password_hash,created_at,updated_at) VALUES (%s,%s,%s,%s,%s,%s)",
                (user_id, email, payload.display_name, ph.hash(payload.password), now, now),
            )
            conn.commit()
    except pymysql.err.IntegrityError:
        raise error(409, "email_already_registered", "Email is already registered.")
    set_session_cookie(response, user_id)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM users WHERE id=%s", (user_id,))
        return {"user": row_to_user(cur.fetchone())}


@app.post("/api/auth/login")
def login(payload: LoginRequest, response: Response) -> dict[str, Any]:
    email = normalize_email(payload.email)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM users WHERE email=%s", (email,))
        user = cur.fetchone()
    if not user:
        raise error(401, "invalid_credentials", "Invalid email or password.")
    try:
        ph.verify(user["password_hash"], payload.password)
    except VerifyMismatchError:
        raise error(401, "invalid_credentials", "Invalid email or password.")
    set_session_cookie(response, user["id"])
    return {"user": row_to_user(user)}


@app.post("/api/auth/logout", status_code=204)
def logout(response: Response, cv_session: str | None = Cookie(default=None), user: dict[str, Any] = Depends(current_user)) -> Response:
    with db() as conn, conn.cursor() as cur:
        cur.execute("UPDATE sessions SET revoked_at=%s WHERE token_hash=%s", (utc_now().replace(tzinfo=None), hash_token(cv_session or "")))
        conn.commit()
    response.delete_cookie(SESSION_COOKIE, path="/")
    return response


@app.get("/api/auth/me")
def me(user: dict[str, Any] = Depends(current_user)) -> dict[str, Any]:
    return {"user": row_to_user(user)}


def validate_upload(file: UploadFile, data: bytes) -> tuple[str, str]:
    filename = sanitize_filename(file.filename or "document")
    suffix = Path(filename).suffix.lower()
    if suffix not in SUPPORTED_EXTENSIONS:
        raise error(415, "unsupported_file_type", "Only PDF and DOCX files are supported.")
    if len(data) > MAX_UPLOAD_BYTES:
        raise error(413, "file_too_large", "File exceeds 25 MB.")
    content_type = file.content_type or ("application/pdf" if suffix == ".pdf" else "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    if content_type not in SUPPORTED_TYPES and suffix in SUPPORTED_EXTENSIONS:
        content_type = "application/pdf" if suffix == ".pdf" else "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    return filename, content_type


def trigger_refresh() -> None:
    try:
        ch().command("SYSTEM REFRESH VIEW ingestion_runs_mv")
    except Exception:
        # The refreshable view interval remains the fallback; upload success should not be rolled back.
        pass


def sync_readiness_for(user_id: str, docs: list[dict[str, Any]]) -> None:
    active = [d for d in docs if d.get("latest_etag") and d["readiness"] != "archived"]
    if not active:
        return
    doc_ids = [d["id"] for d in active]
    try:
        rows = ch().query(
            """
            SELECT document_id, etag, status, chunk_count, last_error
            FROM document_ingestions FINAL
            WHERE user_id = %(user_id)s AND document_id IN %(document_ids)s
            """,
            parameters={"user_id": user_id, "document_ids": tuple(doc_ids)},
        ).result_rows
    except Exception:
        return
    latest = {(r[0], r[1]): r for r in rows}
    updates = []
    for d in active:
        row = latest.get((d["id"], d["latest_etag"]))
        if not row:
            continue
        _, _, status, chunk_count, last_error = row
        readiness = {"completed": "ready", "processing": "processing", "failed": "failed"}[status]
        updates.append((readiness, last_error or None, int(chunk_count), utc_now().replace(tzinfo=None), d["id"], user_id))
    if updates:
        with db() as conn, conn.cursor() as cur:
            cur.executemany(
                "UPDATE managed_documents SET readiness=%s, readiness_error=%s, chunk_count=%s, updated_at=%s WHERE id=%s AND user_id=%s AND archived_at IS NULL",
                updates,
            )
            conn.commit()


def get_docs(user_id: str, where: str = "", params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    with db() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT * FROM managed_documents WHERE user_id=%s AND archived_at IS NULL {where}", (user_id, *params))
        docs = list(cur.fetchall())
    sync_readiness_for(user_id, docs)
    with db() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT * FROM managed_documents WHERE user_id=%s AND archived_at IS NULL {where}", (user_id, *params))
        return list(cur.fetchall())


@app.get("/api/documents")
def list_documents(
    q: str | None = None,
    readiness: str = Query(default="all", pattern="^(all|uploading|processing|ready|failed)$"),
    limit: int = Query(default=25, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    user: dict[str, Any] = Depends(current_user),
) -> dict[str, Any]:
    filters = []
    params: list[Any] = []
    if q:
        filters.append("display_name LIKE %s")
        params.append(f"%{q}%")
    if readiness != "all":
        filters.append("readiness = %s")
        params.append(readiness)
    where = (" AND " + " AND ".join(filters)) if filters else ""
    with db() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT * FROM managed_documents WHERE user_id=%s AND archived_at IS NULL {where} ORDER BY updated_at DESC LIMIT %s OFFSET %s", (user["id"], *params, limit, offset))
        docs = list(cur.fetchall())
        cur.execute(f"SELECT COUNT(*) AS total FROM managed_documents WHERE user_id=%s AND archived_at IS NULL {where}", (user["id"], *params))
        total = cur.fetchone()["total"]
    sync_readiness_for(user["id"], docs)
    docs = get_docs(user["id"], where + " ORDER BY updated_at DESC LIMIT %s OFFSET %s", (*params, limit, offset))
    return {"items": [row_to_document(d) for d in docs], "page": {"limit": limit, "offset": offset, "total": total}}


@app.post("/api/documents", status_code=201)
async def create_document(file: UploadFile = File(...), display_name: str | None = None, user: dict[str, Any] = Depends(current_user)) -> dict[str, Any]:
    data = await file.read()
    filename, content_type = validate_upload(file, data)
    document_id = str(uuid.uuid4())
    name = (display_name or filename).strip()
    now = utc_now().replace(tzinfo=None)
    object_key = f"users/{user['id']}/documents/{document_id}/{filename}"
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO managed_documents
            (id,user_id,display_name,display_name_overridden,original_filename,content_type,size_bytes,readiness,created_at,updated_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,'uploading',%s,%s)
            """,
            (document_id, user["id"], name, bool(display_name), filename, content_type, len(data), now, now),
        )
        conn.commit()
    client = minio_client()
    bucket = ensure_bucket(client)
    client.put_object(bucket, object_key, io.BytesIO(data), length=len(data), content_type=content_type)
    stat = client.stat_object(bucket, object_key)
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE managed_documents
            SET latest_object_key=%s, latest_etag=%s, original_filename=%s, content_type=%s, size_bytes=%s,
                readiness='processing', readiness_error=NULL, chunk_count=0, updated_at=%s
            WHERE id=%s AND user_id=%s
            """,
            (object_key, (stat.etag or "").strip('"'), filename, content_type, len(data), utc_now().replace(tzinfo=None), document_id, user["id"]),
        )
        conn.commit()
    trigger_refresh()
    doc = get_docs(user["id"], "AND id=%s", (document_id,))[0]
    return {"document": row_to_document(doc)}


@app.get("/api/documents/{document_id}")
def get_document(document_id: str, user: dict[str, Any] = Depends(current_user)) -> dict[str, Any]:
    docs = get_docs(user["id"], "AND id=%s", (document_id,))
    if not docs:
        raise error(404, "document_not_found", "Document not found.")
    return {"document": row_to_document(docs[0])}


@app.patch("/api/documents/{document_id}")
def rename_document(document_id: str, payload: RenameDocumentRequest, user: dict[str, Any] = Depends(current_user)) -> dict[str, Any]:
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE managed_documents SET display_name=%s, display_name_overridden=TRUE, updated_at=%s WHERE id=%s AND user_id=%s AND archived_at IS NULL",
            (payload.display_name.strip(), utc_now().replace(tzinfo=None), document_id, user["id"]),
        )
        conn.commit()
        if cur.rowcount == 0:
            raise error(404, "document_not_found", "Document not found.")
    return get_document(document_id, user)


@app.post("/api/documents/{document_id}/replace")
async def replace_document(document_id: str, file: UploadFile = File(...), user: dict[str, Any] = Depends(current_user)) -> dict[str, Any]:
    data = await file.read()
    filename, content_type = validate_upload(file, data)
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM managed_documents WHERE id=%s AND user_id=%s AND archived_at IS NULL", (document_id, user["id"]))
        doc = cur.fetchone()
    if not doc:
        raise error(404, "document_not_found", "Document not found.")
    object_key = f"users/{user['id']}/documents/{document_id}/{filename}"
    client = minio_client()
    bucket = ensure_bucket(client)
    client.put_object(bucket, object_key, io.BytesIO(data), length=len(data), content_type=content_type)
    stat = client.stat_object(bucket, object_key)
    display_name = doc["display_name"] if doc["display_name_overridden"] else filename
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE managed_documents
            SET display_name=%s, latest_object_key=%s, latest_etag=%s, original_filename=%s, content_type=%s,
                size_bytes=%s, readiness='processing', readiness_error=NULL, chunk_count=0, updated_at=%s
            WHERE id=%s AND user_id=%s AND archived_at IS NULL
            """,
            (display_name, object_key, (stat.etag or "").strip('"'), filename, content_type, len(data), utc_now().replace(tzinfo=None), document_id, user["id"]),
        )
        conn.commit()
    trigger_refresh()
    return get_document(document_id, user)


@app.delete("/api/documents/{document_id}", status_code=204)
def archive_document(document_id: str, user: dict[str, Any] = Depends(current_user)) -> Response:
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE managed_documents SET readiness='archived', archived_at=%s, updated_at=%s WHERE id=%s AND user_id=%s AND archived_at IS NULL",
            (utc_now().replace(tzinfo=None), utc_now().replace(tzinfo=None), document_id, user["id"]),
        )
        conn.commit()
        if cur.rowcount == 0:
            raise error(404, "document_not_found", "Document not found.")
    return Response(status_code=204)


@app.get("/api/documents/{document_id}/download")
def download_document(document_id: str, user: dict[str, Any] = Depends(current_user)) -> StreamingResponse:
    docs = get_docs(user["id"], "AND id=%s", (document_id,))
    if not docs or not docs[0].get("latest_object_key"):
        raise error(404, "document_not_found", "Document not found.")
    doc = docs[0]
    obj = minio_client().get_object(os.getenv("MINIO_BUCKET", "documents"), doc["latest_object_key"])
    return StreamingResponse(
        obj.stream(32 * 1024),
        media_type=doc["content_type"],
        headers={"Content-Disposition": f"attachment; filename=\"{doc['original_filename']}\""},
    )


@app.post("/api/query")
def query_documents(payload: QueryRequest, user: dict[str, Any] = Depends(current_user)) -> dict[str, Any]:
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, display_name, latest_etag FROM managed_documents WHERE user_id=%s AND readiness='ready' AND latest_etag IS NOT NULL AND archived_at IS NULL",
            (user["id"],),
        )
        docs = list(cur.fetchall())
    if not docs:
        return {"query": payload.query, "top_k": payload.top_k, "results": []}
    embedding = embed_query(payload.query.strip())
    pair_conditions = []
    params: dict[str, Any] = {"embedding": embedding, "user_id": user["id"], "top_k": payload.top_k}
    for index, doc in enumerate(docs):
        pair_conditions.append(f"(document_id = %(doc_id_{index})s AND etag = %(etag_{index})s)")
        params[f"doc_id_{index}"] = doc["id"]
        params[f"etag_{index}"] = doc["latest_etag"]
    rows = ch().query(
        f"""
        SELECT chunk_id, document_id, chunk_text, chunk_index, cosineDistance(embedding, %(embedding)s) AS distance
        FROM document_chunks
        WHERE user_id = %(user_id)s AND ({' OR '.join(pair_conditions)})
        ORDER BY distance ASC
        LIMIT %(top_k)s
        """,
        parameters=params,
    ).result_rows
    names = {d["id"]: d["display_name"] for d in docs}
    results = []
    for chunk_id, document_id, chunk_text, chunk_index, distance in rows:
        results.append(
            {
                "chunk_id": chunk_id,
                "document_id": document_id,
                "document_display_name": names.get(document_id, "Document"),
                "chunk_text": chunk_text,
                "chunk_index": int(chunk_index),
                "score": round(1 - float(distance), 6),
                "distance": float(distance),
                "download_url": f"/api/documents/{document_id}/download",
            }
        )
    return {"query": payload.query, "top_k": payload.top_k, "results": results}
