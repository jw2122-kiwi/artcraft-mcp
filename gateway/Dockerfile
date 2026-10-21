# syntax=docker/dockerfile:1.7
#
# ArtCraft MCP Gateway - multi-arch (linux/amd64, linux/arm64), reproduzierbar.
#
# Der Build ist in zwei Stufen aufgeteilt:
#   1. "builder" installiert die Python-Abhaengigkeiten in ein venv.
#   2. "runtime" uebernimmt nur das venv und die Craft-CLIs.
#
# Das spart rund 250 MB gegenueber einem Ein-Stufen-Build, weil pip, der
# Compiler-Zeug und die Caches nicht mit ins End-Image wandern.
#
# Wichtig: Alpine (musl) ist nicht moeglich. Die Craft-CLIs sind gegen glibc
# gebaut (GLIBC_2.35) und die Suite liefert keine musl-Builds.

# ---------------------------------------------------------------------------
# Stage 1: Python-Abhaengigkeiten
# ---------------------------------------------------------------------------
FROM python:3.12.15-slim-bookworm AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# Hash-pinned Lock-Datei: dieselben Pakete, unabhaengig von der Architektur
# und unabhaengig davon, was PyPI zur Bauzeit sonst anbietet.
COPY requirements.txt /build/requirements.txt

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --require-hashes -r /build/requirements.txt \
    # __pycache__ und Tests entfernen, Testdateien sind mehrere MB
    && find /opt/venv -type d -name __pycache__ -prune -exec rm -rf {} + \
    && find /opt/venv -type d -name "tests" -prune -exec rm -rf {} + \
    && find /opt/venv -type f -name "*.pyc" -delete \
    # pip und setuptools werden zur Laufzeit nicht gebraucht
    && rm -rf /opt/venv/pip /opt/venv/lib/python3.12/site-packages/pip \
    && rm -rf /opt/venv/lib/python3.12/site-packages/setuptools \
    && rm -rf /opt/venv/lib/python3.12/site-packages/pkg_resources \
    && rm -rf /opt/venv/lib/python3.12/site-packages/_distutils_hack \
    && rm -rf /opt/venv/lib/python3.12/site-packages/distutils

# ---------------------------------------------------------------------------
# Stage 2: Craft-CLIs
#
# Eigene Stufe, damit der Buildschritt von der Python-Installation getrennt
# bleibt. Die Pruefsummen kommen aus dem SHA256SUMS.txt des jeweiligen
# Releases - ohne Abgleich wird nichts installiert.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS craft

ARG TARGETARCH
ARG CRAFT_APPS=all

ENV APPS_DIR=/opt/craft \
    CRAFT_APPS=${CRAFT_APPS}

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY install-craft-apps.sh /usr/local/bin/install-craft-apps.sh
RUN chmod +x /usr/local/bin/install-craft-apps.sh \
    && /usr/local/bin/install-craft-apps.sh

# ---------------------------------------------------------------------------
# Stage 3: Runtime
# ---------------------------------------------------------------------------
FROM python:3.12.15-slim-bookworm AS runtime

# ca-certificates: fuer HTTPS-Downloads zur Laufzeit (nicht zur Bauzeit).
# fontconfig + Liberation/DejaVu: die Renderer der Apps setzen Text ueber
# Fontconfig. Ohne Schrift bleibt der Text in Renders leer oder ersetzt.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        fontconfig \
        fonts-liberation \
        fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -f

COPY --from=builder /opt/venv /opt/venv
COPY --from=craft /opt/craft /opt/craft

COPY server.py /app/server.py
COPY healthcheck.py /app/healthcheck.py

ENV PATH="/opt/venv/bin:$PATH" \
    VIRTUAL_ENV=/opt/venv \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    CRAFT_APPS_DIR=/opt/craft \
    CRAFT_WORK_DIR=/work \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8000 \
    MCP_PATH=/mcp \
    # FastMCP sucht beim Start nach einer ".env" im Arbeitsverzeichnis. Das ist
    # das gemountete Verzeichnis des Host-Users und dort nicht lesbar - der
    # Start bricht dann mit einem PermissionError ab. Ein Pfad, den es nicht
    # gibt, verhindert das.
    FASTMCP_ENV_FILE=/dev/null

# Der Gateway laeuft als unprivilegierter Nutzer mit fester UID. 1000 ist der
# gaengige erste Nicht-System-User; wer den Container als anderer UID
# betreibt, setzt "user:" in der compose.yaml.
RUN groupadd --gid 1000 craft \
    && useradd --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin craft \
    && mkdir -p /work \
    && chown craft:craft /work

USER craft
WORKDIR /work

EXPOSE 8000

HEALTHCHECK --interval=60s --timeout=15s --retries=3 --start-period=30s \
    CMD ["python3", "/app/healthcheck.py"]

CMD ["python3", "/app/server.py"]
