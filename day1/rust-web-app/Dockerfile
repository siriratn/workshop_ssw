# ============================================================
#  Dockerfile — Multi-stage build for Rust Web App
#  Stage 0 : Dev (สำหรับ lint / test เท่านั้น)
#  Stage 1 : Builder  (compile source → binary)
#  Stage 2 : Runtime  (minimal OS image + binary only)
# ============================================================
# ============================================================
#  Multi-stage Dockerfile (dev / builder / runtime)
# ============================================================

# ── Stage 0: Dev (สำหรับ lint / test เท่านั้น) ──────────────
FROM rust:latest AS dev

WORKDIR /app

# install dev tools (lint + format)
RUN rustup component add rustfmt clippy

# (optional) install system deps เผื่อ test ต้องใช้
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# copy source
COPY Cargo.toml ./
COPY src ./src

# ── Stage 1: Builder (compile only) ─────────────────────────
FROM rust:latest AS builder

WORKDIR /app

# install build deps เท่านั้น (lean กว่า dev)
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# copy source
COPY Cargo.toml ./
COPY src ./src

# build release binary
RUN cargo build --release

# ── Stage 2: Runtime (minimal) ──────────────────────────────
FROM debian:bookworm-slim AS runtime

WORKDIR /app

# install runtime deps เท่านั้น
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# copy binary จาก builder
COPY --from=builder /app/target/release/rust-web-app ./rust-web-app

# env
ENV HOST=0.0.0.0
ENV PORT=8080
ENV RUST_LOG=info

EXPOSE 8080

CMD ["./rust-web-app"]