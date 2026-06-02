FROM clickhouse/clickhouse-server:25.5

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv python3-pip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY pipeline/requirements.txt /opt/document-pipeline/requirements.txt
RUN python3 -m venv /opt/document-pipeline/.venv \
    && /opt/document-pipeline/.venv/bin/pip install --no-cache-dir -r /opt/document-pipeline/requirements.txt

COPY pipeline/ingest_runner.py /var/lib/clickhouse/user_scripts/ingest_runner.py
COPY scripts/seed_minio.py /opt/document-pipeline/seed_minio.py
COPY clickhouse/config/document_pipeline.xml /etc/clickhouse-server/config.d/document_pipeline.xml
COPY clickhouse/initdb/001_document_pipeline.sql /docker-entrypoint-initdb.d/001_document_pipeline.sql

RUN chmod 0755 /var/lib/clickhouse/user_scripts/ingest_runner.py \
    && chown -R clickhouse:clickhouse /var/lib/clickhouse/user_scripts /opt/document-pipeline

USER clickhouse
