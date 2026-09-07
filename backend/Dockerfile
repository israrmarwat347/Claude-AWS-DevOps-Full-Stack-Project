FROM python:3.12-slim-bookworm AS builder
WORKDIR /build
COPY backend/requirements.txt .
RUN python -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir --require-hashes -r requirements.txt

FROM python:3.12-slim-bookworm AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 app && useradd --uid 10001 --gid app --no-create-home app
ENV PATH="/opt/venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=10001:10001 backend/app /app/app
COPY --chown=10001:10001 --chmod=0555 backend/entrypoint.sh /app/entrypoint.sh
RUN chown 10001:10001 /tmp
VOLUME ["/tmp"]
USER 10001:10001
EXPOSE 8443
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import ssl,urllib.request; urllib.request.urlopen('https://127.0.0.1:8443/api/health/live',context=ssl._create_unverified_context(),timeout=3)"
ENTRYPOINT ["/app/entrypoint.sh"]
