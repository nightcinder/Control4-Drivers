FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Non-root user. UID 10001 must own the host ./smarthq-bridge/data directory.
RUN groupadd --gid 10001 smarthq \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin smarthq \
    && mkdir -p /data \
    && chown smarthq:smarthq /data

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py .

USER smarthq
VOLUME ["/data"]
EXPOSE 8789

HEALTHCHECK --interval=60s --timeout=5s --start-period=60s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8789/health', timeout=4)"

CMD ["python", "app.py"]
