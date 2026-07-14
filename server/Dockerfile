FROM node:24-bookworm

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /opt/server
RUN ln -s /opt/server /opt/oppi-server

# Tooling for skill compatibility in container runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    docker-compose \
    docker.io \
    ffmpeg \
    git \
    jq \
    openssl \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    tmux \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && printf '#!/bin/sh\nexec /usr/bin/docker-compose "$@"\n' > /usr/local/lib/docker/cli-plugins/docker-compose \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
    && rm -rf /var/lib/apt/lists/*

# uv is required by many skill scripts (#!/usr/bin/env -S uv run ...).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && ln -sf /root/.local/bin/uv /usr/local/bin/uv

COPY server/package.json server/package-lock.json ./
RUN npm ci --no-audit --no-fund --ignore-scripts

COPY server/ ./
RUN npm run build \
    && ln -sf /opt/server/dist/src/cli.js /usr/local/bin/oppi

COPY server/docker/entrypoint.sh /usr/local/bin/oppi-entrypoint.sh
RUN chmod +x /usr/local/bin/oppi-entrypoint.sh

ENV OPPI_DATA_DIR=/data/oppi
ENV PI_CODING_AGENT_DIR=/data/pi-agent
ENV PI_AGENT_SEED_DIR=/seed/pi-agent
ENV PI_AGENT_SYNC_MODE=copy-once
ENV SEARXNG_URL=http://host.docker.internal:8888

EXPOSE 7750

ENTRYPOINT ["/usr/local/bin/oppi-entrypoint.sh"]
