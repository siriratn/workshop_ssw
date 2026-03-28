

## วิธีเรียกใช้ pipeline.sh
``` 
chmod +x pipeline.sh


## STAGE 1 — LINT  (cargo fmt + clippy)
./pipeline.sh lint

# STAGE 2 — TEST  (cargo test)
./pipeline.sh test

# STAGE 3 — BUILD  (docker build image)
./pipeline.sh build

# STAGE 4 — DEPLOY  (docker run container)
./pipeline.sh deploy

# รันทุก stage พร้อมกัน
./pipeline.sh

```
## ====================================================

## เปลี่ยน port
```
HOST_PORT=9090 ./pipeline.sh deploy

# build + push ขึ้น registry
REGISTRY=ghcr.io/myuser ./pipeline.sh build

# กำหนด tag เอง
TAG=v1.0.0 ./pipeline.sh build
```


## ====================================================

## build image
```
$ docker build -t rust-web-app:1.0 .
$ docker run -dt --name=rust-web -d -p 8080:8080 -v $(pwd)/.env:/app/.env rust-web-app:1.0
```


## ทดสอบ hot-reload:
```
echo "DATABASE_URI=postgres://user:pass@10.0.0.2:5432/newdb" >> .env
curl http://localhost:8080/   # เห็น database_url ใหม่ทันที
```

## ====================================================

# Component ตามโจทย์
 
| โจทย์ | ไฟล์ | คำอธิบาย |
|-------|------|----------|
| Source Code | `src/main.rs` | โค้ด Rust ทั้งหมด |
| Package Manager | `Cargo.toml` (Cargo) | จัดการ dependencies |
| Dependency File | `Cargo.toml` `[dependencies]` | ระบุ library ที่ใช้ |
| App Runtime | Tokio (async runtime) | รัน event loop |
| App Package / OS Executable | `Dockerfile` (binary) | compile → binary ใน container |

