# ============================================================
# VIBE FEARLESS / KANHAMUSIC
# Multi-stage Docker build for Render
# ============================================================

# -------------------- BUILD STAGE ---------------------------
FROM golang:1.26.2-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV CGO_ENABLED=1
ENV GOMAXPROCS=2
ENV GOFLAGS="-p=2"

WORKDIR /build

# Install native build dependencies required by CGO and libraries.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        g++ \
        make \
        pkg-config \
        curl \
        unzip \
        ca-certificates \
        zlib1g-dev \
        libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# Copy Go dependency manifests first for better build caching.
COPY go.mod go.sum ./

RUN go mod download

# Copy the complete repository.
COPY . .

# Ensure installer is executable and required directories exist.
RUN chmod +x install.sh && \
    mkdir -p /build/config/cookies

# Install native libraries required by the application.
RUN ./install.sh -n -t --quiet --skip-summary

# Verify the TDLib library exists before compiling.
RUN test -f /build/libtdjson.so.1.8.66 || \
    (echo "ERROR: Required TDLib library was not installed." && exit 1)

# Build with limited concurrency to reduce memory pressure.
# Save complete logs and display the final lines if compilation fails.
RUN set -eu; \
    if ! CGO_ENABLED=1 GOMAXPROCS=2 \
        go build -p 2 -trimpath \
        -ldflags="-w -s" \
        -o /build/app ./cmd/app/ \
        > /tmp/go-build.log 2>&1; then \
        echo "========== GO BUILD FAILED =========="; \
        tail -n 150 /tmp/go-build.log; \
        exit 1; \
    fi; \
    test -x /build/app

# -------------------- RUNTIME STAGE -------------------------
FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ffmpeg \
        libssl3 \
        libstdc++6 \
        libgcc-s1 \
        zlib1g \
        libgomp1 && \
    rm -rf /var/lib/apt/lists/*

# Install yt-dlp.
RUN curl -fL --retry 3 \
        https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux \
        -o /usr/local/bin/yt-dlp && \
    chmod 0755 /usr/local/bin/yt-dlp

# Install Deno for JavaScript-dependent YouTube extraction.
RUN curl -fsSL --retry 3 \
        https://deno.land/install.sh \
        -o /tmp/deno-install.sh && \
    DENO_INSTALL=/usr/local sh /tmp/deno-install.sh -y --no-modify-path && \
    test -x /usr/local/bin/bin/deno && \
    ln -sf /usr/local/bin/bin/deno /usr/local/bin/deno && \
    rm -f /tmp/deno-install.sh

# Application environment.
ENV PATH="/usr/local/bin:${PATH}"
ENV LD_LIBRARY_PATH="/app:/usr/local/lib:/usr/lib"
ENV TDJSON_PATH="/app/libtdjson.so.1.8.66"

# Create a non-root user.
RUN useradd --system --uid 10001 --create-home appuser && \
    mkdir -p /app/config/cookies && \
    chown -R appuser:appuser /app

WORKDIR /app

# Copy compiled application and TDLib from the build stage.
COPY --from=builder --chown=appuser:appuser \
    /build/app /app/app

COPY --from=builder --chown=appuser:appuser \
    /build/libtdjson.so.1.8.66 /app/libtdjson.so.1.8.66

# Copy cookie directory if present in the repository.
COPY --from=builder --chown=appuser:appuser \
    /build/config/cookies/ /app/config/cookies/

# Verify runtime files and shared-library dependencies.
RUN test -x /app/app && \
    test -f /app/libtdjson.so.1.8.66 && \
    chmod 0755 /app/app && \
    ldconfig

USER appuser

# Start the bot.
ENTRYPOINT ["/app/app"]
