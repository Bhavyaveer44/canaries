FROM python:3.12-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim

WORKDIR /app
RUN useradd --create-home appuser
COPY --from=builder /install /usr/local
COPY worker.py .
USER appuser

# Without this, Python block-buffers stdout when it's not attached to
# a real terminal (true for any detached container) - print()
# statements can sit in memory indefinitely instead of reaching
# `docker compose logs`, even though the process is running fine.
ENV PYTHONUNBUFFERED=1

CMD ["python", "worker.py"]