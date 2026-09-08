# builder stage
# Everything needed to INSTALL dependencies (compilers, build tools
# some pip packages need) lives only in this stage.
FROM python:3.12-slim AS builder

WORKDIR /app
COPY requirements.txt .

# Install into a local prefix instead of system site-packages so we
# can cleanly copy *just* the installed packages into the next stage.
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- final stage ----
# Starts fresh from a clean slim image. None of the build tools from
# the builder stage exist here - only the compiled/installed packages
# we explicitly copy over.
FROM python:3.12-slim

WORKDIR /app

# Run as a non-root user - if this container is ever compromised via
# a dependency vulnerability, the attacker doesn't get root inside it.
RUN useradd --create-home appuser
COPY --from=builder /install /usr/local
COPY app ./app
USER appuser

ENV PYTHONUNBUFFERED=1

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]