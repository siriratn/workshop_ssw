# ============================================================
#  Dockerfile — Multi-stage build for Rust Web App
#  Stage 0 : Dev/Builder  (lint + test + compile)
#  Stage 1 : Runtime      (minimal OS image + binary only)
#
#  ใช้คู่กับ pipeline.sh:
#    ensure_dev_image()  → docker build --target dev   -t rust-dev .
#    stage_build()       → docker build                -t <image>  .
# ============================================================

# ── Stage 0: Dev + Builder (รวมกัน) ─────────────────────────
FROM rustlang/rust:nightly-slim AS dev

WORKDIR /app

# dev tools (lint) + build deps รวมใน RUN เดียว → layer เดียว
RUN apt-get update && apt-get install -y \
      pkg-config \
      libssl-dev \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add rustfmt clippy


# copy source
COPY Cargo.toml ./
COPY src ./src

# build release binary
RUN cargo build --release


# ── Stage 1: Runtime (minimal) ──────────────────────────────
FROM debian:bookworm-slim AS runtime

WORKDIR /app

# non-root user  
RUN groupadd -r appgroup && useradd -r -g appgroup appuser \
    && apt-get update && apt-get install -y \
         ca-certificates \
         libssl3 \
         wget \
    && rm -rf /var/lib/apt/lists/*

# copy binary จาก dev stage (ที่ทำ cargo build --release ไว้แล้ว)
COPY --from=dev /app/target/release/rust-web-app ./rust-web-app
RUN chown appuser:appgroup ./rust-web-app

USER appuser

ENV HOST=0.0.0.0
ENV PORT=8080
ENV RUST_LOG=info

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["./rust-web-app"]