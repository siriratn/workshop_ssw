# ============================================================
#  Dockerfile — Python Web App
#  ใช้ python:3.12-slim — มีแค่ Python interpreter ไม่มี extras
# ============================================================

FROM python:3.12-slim

WORKDIR /app

# Copy Dependency File
# pip install จะอ่าน requirements.txt
# กรณีนี้ไม่มี external dep แต่เป็น best practice ที่ควรมี
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy Source Code
COPY main.py ./

ENV HOST=0.0.0.0
ENV PORT=8080

EXPOSE 8080

# App Runtime = python interpreter  |  OS Executable = main.py
CMD ["python", "main.py"]
