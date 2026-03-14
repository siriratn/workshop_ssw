# ============================================================
#  Dockerfile — Multi-stage build for Rust Web App
#  Stage 1 : Builder  (compile source → binary)
#  Stage 2 : Runtime  (minimal OS image + binary only)
# ============================================================

# ── Stage 1: Builder ─────────────────────────────────────────
FROM rust:latest AS builder

# Set working directory
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy all project files
COPY Cargo.toml ./
COPY src ./src

# Build the release binary
RUN cargo build --release

# ── Stage 2: Runtime ─────────────────────────────────────────
# Use a minimal Debian image — no Rust toolchain needed
FROM debian:bookworm-slim AS runtime

WORKDIR /app

# Install only the runtime libraries needed (libssl)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled binary from builder stage
COPY --from=builder /app/target/release/rust-web-app ./rust-web-app

# Environment variables
ENV HOST=0.0.0.0
ENV PORT=8080
ENV RUST_LOG=info

# Expose the application port
EXPOSE 8080

# App Runtime entry-point (OS Executable)
CMD ["./rust-web-app"]
