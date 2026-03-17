# ============================================================
#  Dockerfile — Multi-stage build สำหรับ Dart Web App
#  Stage 1 : Builder  — dart compile exe → native binary
#  Stage 2 : Runtime  — debian-slim + binary เท่านั้น
# ============================================================

# ── Stage 1: Builder ─────────────────────────────────────────
FROM dart:stable AS builder

WORKDIR /app

# Copy Dependency File ก่อน
COPY pubspec.yaml ./

# Package Manager: pub — download dependencies
# กรณีนี้ไม่มี external dep แต่ยังต้อง run เพื่อสร้าง .dart_tool/
RUN dart pub get

# Copy Source Code
COPY main.dart ./

# Compile เป็น native binary (AOT compilation)
# dart compile exe = Ahead-of-Time compile → standalone binary
# ไม่ต้องการ Dart SDK ตอนรัน
RUN dart compile exe main.dart -o app

# ── Stage 2: Runtime ─────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

WORKDIR /app

RUN apt-get update && apt-get install -y \
    libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled binary (OS Executable)
COPY --from=builder /app/app ./app

ENV HOST=0.0.0.0
ENV PORT=8080

EXPOSE 8080

# App Runtime entry-point — binary รันได้เลยโดยไม่ต้องการ Dart SDK
CMD ["./app"]
