# ============================================================
#  Dockerfile — Bash Web App
#  ใช้ alpine เพราะเล็ก (~5MB) และมี bash + netcat ให้ติดตั้งได้
# ============================================================

FROM alpine:3.19

# ติดตั้ง tools ที่ script ต้องการ
# bash         — รัน #!/bin/bash (alpine ใช้ sh เป็นค่าเริ่มต้น)
# netcat-openbsd — nc สำหรับรับ TCP connection
# coreutils    — dd, date พร้อม option ครบ
# util-linux   — flock สำหรับ file locking
RUN apk add --no-cache \
    bash \
    netcat-openbsd \
    coreutils \
    util-linux

WORKDIR /app

# Source Code
COPY main.sh .

# ให้ execute permission
RUN chmod +x main.sh

ENV HOST=0.0.0.0
ENV PORT=8080

EXPOSE 8080

# App Runtime entry-point
CMD ["bash", "main.sh"]
