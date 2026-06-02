#!/opt/document-pipeline/.venv/bin/python
import os
import sys
import tempfile
from pathlib import Path

from minio import Minio
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas


def get_minio_client():
    return Minio(
        os.environ.get("MINIO_ENDPOINT", "minio:9000"),
        access_key=os.environ.get("MINIO_ACCESS_KEY", "minioadmin"),
        secret_key=os.environ.get("MINIO_SECRET_KEY", "minioadmin"),
        secure=os.environ.get("MINIO_SECURE", "false").lower() == "true",
    )


def write_pdf(path: str, title: str, paragraphs: list[str]) -> None:
    pdf = canvas.Canvas(path, pagesize=letter)
    width, height = letter
    y = height - 72
    pdf.setFont("Helvetica-Bold", 14)
    pdf.drawString(72, y, title)
    y -= 28
    pdf.setFont("Helvetica", 10)
    for paragraph in paragraphs:
        for line in wrap(paragraph, 92):
            if y < 72:
                pdf.showPage()
                pdf.setFont("Helvetica", 10)
                y = height - 72
            pdf.drawString(72, y, line)
            y -= 14
        y -= 8
    pdf.save()


def wrap(text: str, width: int) -> list[str]:
    words = text.split()
    lines = []
    current = []
    for word in words:
        candidate = " ".join(current + [word])
        if len(candidate) > width and current:
            lines.append(" ".join(current))
            current = [word]
        else:
            current.append(word)
    if current:
        lines.append(" ".join(current))
    return lines


def upload_pdf(client: Minio, bucket: str, object_key: str, title: str, paragraphs: list[str]) -> None:
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)
    with tempfile.TemporaryDirectory() as tmp:
        path = str(Path(tmp) / "document.pdf")
        write_pdf(path, title, paragraphs)
        client.fput_object(bucket, object_key, path, content_type="application/pdf")
        stat = client.stat_object(bucket, object_key)
        print(f"uploaded {bucket}/{object_key} etag={stat.etag}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: seed_minio.py initial|add|update", file=sys.stderr)
        return 2

    mode = sys.argv[1]
    bucket = os.environ.get("MINIO_BUCKET", "documents")
    client = get_minio_client()

    if mode == "initial":
        upload_pdf(
            client,
            bucket,
            "incoming/policy-handbook.pdf",
            "Policy Handbook",
            [
                "This handbook describes onboarding policy, document retention, access review, and escalation process for internal teams.",
                "The retention rule requires source documents to stay in MinIO while searchable chunks are stored in ClickHouse.",
            ],
        )
    elif mode == "add":
        upload_pdf(
            client,
            bucket,
            "incoming/security-guide.pdf",
            "Security Guide",
            [
                "The security guide explains credential rotation, audit logging, encryption expectations, and operational ownership.",
                "Embedding requests use the configured provider and must not store API secrets in repository files.",
            ],
        )
        upload_pdf(
            client,
            bucket,
            "incoming/product-notes.pdf",
            "Product Notes",
            [
                "Product notes summarize retrieval behavior, latest completed document versions, and cosine distance ranking.",
                "The first integration intentionally supports one ingestion runner and a bounded number of documents per run.",
            ],
        )
    elif mode == "update":
        upload_pdf(
            client,
            bucket,
            "incoming/policy-handbook.pdf",
            "Policy Handbook Updated",
            [
                "This updated handbook adds a clear incident response section and changes the retention guidance for review workflows.",
                "Updated source documents create a new document version when the MinIO etag changes.",
                "Retrieval should prefer the latest completed version of each object key.",
            ],
        )
    else:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
