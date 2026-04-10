# ============================================================
#  Dockerfile — Multi-stage build สำหรับ Dart Web App
#
#  Stage dev     : dart SDK สำหรับ lint/test (pipeline.sh ใช้)
#  Stage builder : dart compile exe → native binary
#  Stage runtime : debian-slim + binary + .env mount เท่านั้น
# ============================================================

# ── Stage: dev (ใช้โดย pipeline.sh สำหรับ lint และ test) ────
FROM dart:stable AS dev

WORKDIR /app
COPY pubspec.yaml ./
RUN dart pub get
COPY . .

# ── Stage: builder — compile เป็น native binary ──────────────
FROM dev AS builder

# dart compile exe = AOT compile → standalone binary
# ไม่ต้องการ Dart SDK ตอนรัน
RUN dart compile exe main.dart -o app

# ── Stage: runtime — minimal image + binary only ─────────────
FROM debian:bookworm-slim AS runtime

WORKDIR /app

RUN apt-get update && apt-get install -y \
    libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled binary (OS Executable)
COPY --from=builder /app/app ./app

# .env จะถูก mount เข้ามาตอน docker run ผ่าน -v
# ถ้าไม่ mount จะใช้ค่าจาก ENV ที่ set ไว้
ENV HOST=0.0.0.0
ENV PORT=8080
ENV ENV_FILE=/app/.env

EXPOSE 8080

CMD ["./app"]
