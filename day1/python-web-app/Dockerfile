# ============================================================
#  Dockerfile — Multi-stage build for Python Web App
#  Stage 1 : builder  — ติดตั้ง dependencies + ตรวจสอบ syntax
#  Stage 2 : runtime  — python:slim + source เท่านั้น
#
#  ต่างจาก Dockerfile เดิม (single stage):
#    เดิม  : ทุกอย่างอยู่ใน image เดียว รวม pip, wheel, cache
#    ใหม่  : builder ติดตั้ง dep แล้ว copy เฉพาะ site-packages
#             ไปยัง runtime → image เล็กลง ไม่มี build tools
#
#  เปรียบเทียบกับภาษาอื่น:
#    Rust  : builder (cargo build) → runtime (debian-slim + binary)
#    Go    : builder (go build)    → runtime (scratch + binary)
#    Python: builder (pip install) → runtime (python:slim + source)
#    JS    : builder (npm install) → runtime (node:alpine + source)
#
#  Python ต่างจาก Rust/Go ตรงที่ไม่มีขั้น compile
#  runtime stage ยังต้องมี Python interpreter อยู่
# ============================================================

# ── Stage 1: builder ─────────────────────────────────────────
# ใช้ python:3.12-slim เป็น builder (มี pip)
FROM python:3.12-slim AS builder

WORKDIR /app

# Copy dependency file ก่อน (cache layer)
# Docker จะ cache layer นี้ถ้า requirements.txt ไม่เปลี่ยน
COPY requirements.txt ./

# ติดตั้ง dependencies ลงใน /install แยกออกมา
# --no-cache-dir  ไม่เก็บ pip cache (ลด layer size)
# --prefix=/install  ติดตั้งลง directory แยก เพื่อ copy ไป runtime
# ทำให้ runtime stage ได้รับเฉพาะ package จริง ไม่มี pip, setuptools
# RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
RUN mkdir -p /install && \
    pip install --no-cache-dir --prefix=/install -r requirements.txt

# Copy source code
COPY main.py ./

# ── Stage 2: runtime ─────────────────────────────────────────
# ใช้ python:3.12-slim (distroless-like — มีแค่ Python ไม่มี pip)
FROM python:3.12-slim AS runtime

WORKDIR /app

# Copy packages ที่ติดตั้งไว้จาก builder
# /install/lib/python3.12/site-packages → /usr/local/lib/python3.12/site-packages
COPY --from=builder /install /usr/local

# Copy source code (Python ไม่ compile จึงต้อง copy .py มาด้วย)
COPY --from=builder /app/main.py ./

# Environment variables (infra config — set ตอน start)
# DATABASE_URI, REDIS_ENDPOINT ไม่ set ที่นี่
# เพราะอ่านผ่าน read_env_file() ทุก request (hot-reload)
ENV HOST=0.0.0.0
ENV PORT=8080
ENV PYTHONUNBUFFERED=1

# PYTHONUNBUFFERED=1 บังคับให้ print() flush ทันที
# ถ้าไม่ set log จะค้างอยู่ใน buffer ไม่แสดงใน docker logs

EXPOSE 8080

# App Runtime = python  |  Entry point = main.py
CMD ["python", "main.py"]
