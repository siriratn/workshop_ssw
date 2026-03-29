#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  pipeline.sh — Go Build Pipeline (Docker-native)
#  ไม่ต้องติดตั้ง Go บนเครื่อง — ใช้ Docker ทั้งหมด
#
#  Go (toolchain)            │  pipeline.sh
#  ──────────────────────────┼──────────────────────────────
#  gofmt + go vet            │  stage_lint
#  go test                   │  stage_test
#  docker build (multi-stage)│  stage_build
#  docker run                │  stage_deploy
#
#  อ้างอิงจาก: pipeline.sh ภาษา Rust
#  ความแตกต่างหลัก:
#    Rust → cargo fmt / cargo clippy / cargo test / cargo build
#    Go   → gofmt / go vet / go test / go build (ผ่าน Dockerfile)
# ============================================================

# ─── CONFIG ──────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-go-web-app}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGISTRY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-go-web-app}"
HOST_PORT="${HOST_PORT:-8080}"
# GO_IMAGE ใช้รัน lint/test ก่อน build จริง
# golang:1.22-alpine ตรงกับ builder stage ใน Dockerfile
# GO_IMAGE="${GO_IMAGE:-golang:1.22-alpine}"

# สำหรับ Lint/Test (pipeline)ตรวจคุณภาพ + race  Debian (golang:1.22)
GO_IMAGE="golang:1.22"

# ─── Helpers ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)] $*${NC}"; }
ok()   { echo -e "${GREEN}  ✔ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
die()  { echo -e "${RED}  ✘ $*${NC}"; exit 1; }

# ─── resolve_image() ─────────────────────────────────────────
# ฟังก์ชันกลาง — ใช้ร่วมกันระหว่าง stage_build และ stage_deploy
# เพื่อให้ TAG=v1.0.0 build และ TAG=v1.0.0 deploy ชี้ image เดียวกันเสมอ
resolve_image() {
  if [[ -n "$REGISTRY" ]]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest"
  else
    FULL_IMAGE="${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${IMAGE_NAME}:latest"
  fi
}

# ─── ตรวจว่ามี Docker ────────────────────────────────────────
check_docker() {
  command -v docker &>/dev/null \
    || die "ไม่พบ Docker — ติดตั้งที่ https://docs.docker.com/get-docker/"
  docker info &>/dev/null \
    || die "Docker daemon ไม่ทำงาน — กรุณาเปิด Docker Desktop"
}

# ============================================================
#  STAGE 1 — LINT
#
#  เทียบกับ Rust pipeline:
#     Go : gofmt -l (ตรวจ format)
#     Go : go vet   (static analysis)
#
#  รันใน golang:alpine container — ไม่ต้องติดตั้ง Go บนเครื่อง
#  mount source code เข้าผ่าน -v แล้วรัน tool ใน container
# ============================================================
stage_lint() {
  log "STAGE 1/4 — LINT"
  log "  gofmt -l  (ตรวจ code format)"
  log "  go vet    (static analysis)"

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$GO_IMAGE" \
    sh -c '
      echo ">>> gofmt -l ." &&
      UNFORMATTED=$(gofmt -l .) &&
      if [ -n "$UNFORMATTED" ]; then
        echo "✘ ไฟล์ต่อไปนี้ยังไม่ได้ format:" &&
        echo "$UNFORMATTED" &&
        echo "  แก้ด้วย: gofmt -w ." &&
        exit 1
      fi &&
      echo "✔ gofmt passed" &&
      echo ">>> go vet ./..." &&
      go vet ./... &&
      echo "✔ go vet passed"
    '

  ok "LINT PASSED"
}

# ============================================================
#  STAGE 2 — TEST
#
#    Go   : go test -v -race -count=1 ./...
#
#  flag สำคัญ:
#    -v       แสดง test name ทุกตัว (เทียบ --nocapture)
#    -race    ตรวจ data race ใน goroutine (สำคัญสำหรับ store.mu)
#    -count=1 บังคับรันใหม่ทุกครั้ง ไม่ใช้ cache
#
#  สร้าง .env ชั่วคราวถ้าไม่มี เพราะ readEnvFile() อ่านจากดิสก์จริง
# ============================================================
stage_test() {
  log "STAGE 2/4 — TEST"
  log "  go test -v -race -count=1 ./..."

  # สร้าง .env ชั่วคราวสำหรับ test ถ้ายังไม่มี
  CLEANUP_ENV=false
  if [[ ! -f ".env" ]]; then
    warn "ไม่พบ .env — สร้างไฟล์ชั่วคราวสำหรับ test"
    cat > .env <<'EOF'
DATABASE_URI=postgres://test:test@localhost:5432/testdb
REDIS_ENDPOINT=redis://localhost:6379
HOST=0.0.0.0
PORT=8080
EOF
    CLEANUP_ENV=true
  fi

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$GO_IMAGE" \
    sh -c '
      echo ">>> go test -v -race -count=1 ./..." &&
      go test -v -race -count=1 ./... &&
      echo "✔ tests passed"
    '

  TEST_EXIT=$?

  [[ "$CLEANUP_ENV" == "true" ]] && rm -f .env && log "  ลบ .env ชั่วคราวแล้ว"

  [[ $TEST_EXIT -ne 0 ]] && die "TEST FAILED"

  ok "TEST PASSED"
}

# ============================================================
#  STAGE 3 — BUILD & PUBLISH
#
#   Go : go build (ผ่าน Dockerfile stage builder)
#   Go : docker build (multi-stage เหมือนกัน)
#
#  Dockerfile Go ใช้ FROM scratch ใน runtime stage
#  ทำให้ image เล็กกว่า Rust (debian-slim) มาก (~10MB vs ~80MB)
#
#  tag สองชื่อพร้อมกัน:
#    <image>:<TAG>    เช่น go-web-app:v1.0.0
#    <image>:latest
# ============================================================
stage_build() {
  log "STAGE 3/4 — BUILD & PUBLISH"

  resolve_image
  log "  Image : $FULL_IMAGE"

  # build image — Dockerfile จะรัน go build ใน builder stage อัตโนมัติ
  docker build \
    -t "$FULL_IMAGE" \
    -t "$LATEST_IMAGE" \
    .

  ok "BUILD SUCCESS: $FULL_IMAGE"

  # แสดงขนาด image (Go + scratch จะเล็กมาก)
  local size
  size=$(docker image inspect "$LATEST_IMAGE" \
    --format='{{printf "%.1f MB" (div (index .Size) 1048576.0)}}' 2>/dev/null \
    || echo "unknown")
  log "  Image size: $size"

  # push ไป registry ถ้ากำหนดไว้
  if [[ -n "$REGISTRY" ]]; then
    log "  PUSH → $REGISTRY"
    docker push "$FULL_IMAGE"
    docker push "$LATEST_IMAGE"
    ok "PUSH SUCCESS"
  else
    warn "ไม่มี REGISTRY — build local เท่านั้น (ไม่ push)"
    warn "กำหนด: REGISTRY=ghcr.io/user ./pipeline.sh build"
  fi
}

# ============================================================
#  STAGE 4 — DEPLOY
#
#  เทียบกับ Rust pipeline:
#    ทั้งสองใช้ resolve_image() เดียวกัน → TAG=v1.0.0 deploy ชี้ image เดิม
#
#  จุดต่างจาก Rust:
#    Go ไม่มี RUST_LOG — ใช้ log package ของ standard library แทน
#
#  hot-reload config:
#    -v .env:/app/.env:ro  mount ไฟล์ .env เข้า container
#    เมื่อแก้ .env บน host → readEnvFile() อ่านค่าใหม่ทุก GET /
#    ไม่ต้อง restart container
#
#  TAG resolution:
#    TAG=v1.0.0 ./pipeline.sh deploy  → go-web-app:v1.0.0
#    TAG=v0.9.0 ./pipeline.sh deploy  → go-web-app:v0.9.0  (rollback)
#    TAG=latest ./pipeline.sh deploy  → go-web-app:latest
#    ./pipeline.sh deploy             → go-web-app:<git-sha>
# ============================================================
stage_deploy() {
  log "STAGE 4/4 — DEPLOY"

  resolve_image
  log "  Image : $FULL_IMAGE"

  # ตรวจว่า image มีอยู่จริงก่อน deploy
  if ! docker image inspect "$FULL_IMAGE" &>/dev/null; then
    die "ไม่พบ image '${FULL_IMAGE}'\nรัน build ก่อน: TAG=${TAG} ./pipeline.sh build"
  fi

  # ตรวจ .env สำหรับ hot-reload
  if [[ ! -f ".env" ]]; then
    if [[ -f ".env.example" ]]; then
      cp .env.example .env
      warn "คัดลอก .env.example → .env"
    else
      die "ไม่พบ .env — กรุณาสร้างไฟล์ .env ก่อน deploy"
    fi
  fi

  # หยุดและลบ container เก่า
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "  หยุด container เก่า: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME"
  fi

  # รัน container ใหม่
  # -v .env:/app/.env:ro
  #   mount .env เข้า /app/.env แบบ read-only
  #   Go image ใช้ FROM scratch ดังนั้น path /app ต้องตรงกับที่ binary อยู่
  #   readEnvFile(".env") จะหาไฟล์นี้ทุกครั้งที่ GET / ถูกเรียก
  #
  # --env-file .env
  #   โหลด HOST, PORT เข้า process env ตอน start (ใช้แค่ infra config)
  #   DATABASE_URI, REDIS_ENDPOINT จะไม่ถูกอ่านผ่านทางนี้
  #   แต่อ่านจากไฟล์ผ่าน readEnvFile() แทน
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:8080" \
    -e HOST=0.0.0.0 \
    -e PORT=8080 \
    -v "$(pwd)/.env:/app/.env:ro" \
    --env-file .env \
    --restart unless-stopped \
    "$FULL_IMAGE"

  ok "DEPLOY SUCCESS"
  log "  Container : $CONTAINER_NAME"
  log "  Image     : $FULL_IMAGE"
  log "  URL       : http://localhost:${HOST_PORT}"
  log ""
  log "  ดู logs   : docker logs -f $CONTAINER_NAME"
  log "  หยุด      : docker stop $CONTAINER_NAME"
  log ""
  log "  Hot-reload: แก้ .env แล้ว curl http://localhost:${HOST_PORT}/ → เห็นค่าใหม่ทันที"
}

# ============================================================
#  Usage
# ============================================================
usage() {
  echo ""
  echo -e "${CYAN}วิธีใช้: ./pipeline.sh [stage]${NC}"
  echo ""
  echo "STAGE 1: LINT"
  echo "  gofmt -l .      ตรวจ code format  (เทียบ cargo fmt --check)"
  echo "  go vet ./...    static analysis   (เทียบ cargo clippy)"
  echo ""
  echo "STAGE 2: TEST"
  echo "  go test -v -race -count=1 ./..."
  echo ""
  echo "STAGE 3: BUILD & PUBLISH"
  echo "  docker build (multi-stage: go build --release → scratch image)"
  echo "  docker push  (ถ้ากำหนด REGISTRY)"
  echo ""
  echo "STAGE 4: DEPLOY"
  echo "  docker run + mount .env สำหรับ hot-reload config"
  echo ""
  echo "commands:"
  echo "  ./pipeline.sh [lint|test|build|deploy|all]"
  echo ""
  echo "Environment variables:"
  echo "  IMAGE_NAME=go-web-app     ชื่อ Docker image"
  echo "  TAG=v1.0.0                image tag (default: git short SHA)"
  echo "  REGISTRY=ghcr.io/user     push ไป registry (optional)"
  echo "  HOST_PORT=8080            port บน host machine"
  echo "  CONTAINER_NAME=go-web-app"
  echo "  GO_IMAGE=golang:1.22-alpine  image สำหรับ lint/test"
  echo ""
  echo "ตัวอย่าง:"
  echo "  ./pipeline.sh                                       # รันทุก stage"
  echo "  ./pipeline.sh lint                                  # เฉพาะ lint"
  echo "  ./pipeline.sh test                                  # เฉพาะ test"
  echo "  TAG=v1.0.0 ./pipeline.sh build                     # build image:v1.0.0"
  echo "  TAG=v1.0.0 ./pipeline.sh deploy                    # deploy image:v1.0.0"
  echo "  TAG=v0.9.0 ./pipeline.sh deploy                    # rollback ไป v0.9.0"
  echo "  TAG=latest ./pipeline.sh deploy                    # deploy image:latest"
  echo "  REGISTRY=ghcr.io/user TAG=v1.0.0 ./pipeline.sh build  # build+push"
  echo "  HOST_PORT=9090 ./pipeline.sh deploy                # deploy port 9090"
  echo ""
}

# ============================================================
#  Main
# ============================================================
main() {
  check_docker

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Go Build Pipeline  (Docker-native)     ║${NC}"
  echo -e "${CYAN}║   Image : ${IMAGE_NAME}:${TAG}${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  case "${1:-all}" in
    lint)   stage_lint   ;;
    test)   stage_test   ;;
    build)  stage_build  ;;
    deploy) stage_deploy ;;
    all)
      stage_lint
      stage_test
      stage_build
      stage_deploy
      ;;
    help|-h|--help) usage ;;
    *) die "ไม่รู้จัก stage: '${1}'\nใช้: ./pipeline.sh [lint|test|build|deploy|all]" ;;
  esac
}

main "$@"
