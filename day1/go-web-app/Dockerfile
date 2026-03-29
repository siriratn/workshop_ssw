# ============================================================
#  Dockerfile — Multi-stage build สำหรับ Go Web App
#  Stage 1 : Builder  — compile source → binary
#  Stage 2 : Runtime  — image เล็กสุด + binary เท่านั้น
# ============================================================

# ── Stage 1: Builder ─────────────────────────────────────────
FROM golang:1.22-alpine AS builder

# alpine เล็กกว่า debian มาก (~5MB vs ~80MB)
# ติดตั้ง ca-certificates สำหรับ HTTPS calls (ถ้าต้องการ)
RUN apk add --no-cache ca-certificates

WORKDIR /app

# Copy Dependency File ก่อน
# Docker จะ cache layer นี้ไว้ ถ้า go.mod ไม่เปลี่ยนก็ไม่ต้อง download ใหม่
COPY go.mod ./

# Download dependencies (กรณีนี้ไม่มี external dep จึงเร็วมาก)
RUN go mod download

# Copy Source Code
COPY *.go ./

# Build binary
# CGO_ENABLED=0  → ไม่ใช้ C library ทำให้ binary รันได้บน image ที่ไม่มี libc
# GOOS=linux     → target OS
# -ldflags "-s -w" → ลด binary size (strip debug symbols)
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o go-web-app .

# ── Stage 2: Runtime ─────────────────────────────────────────
# scratch = image ว่างเปล่า ไม่มี OS ไม่มีอะไรเลย
# binary Go แบบ static ไม่ต้องการ OS libraries จึงรันบน scratch ได้
FROM scratch AS runtime

WORKDIR /app

# Copy CA certs จาก builder (สำหรับ HTTPS)
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy binary (OS Executable) จาก builder stage
COPY --from=builder /app/go-web-app /go-web-app

# Environment variables
ENV HOST=0.0.0.0
ENV PORT=8080

EXPOSE 8080

# App Runtime entry-point
CMD ["/go-web-app"]
