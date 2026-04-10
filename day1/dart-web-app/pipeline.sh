#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  pipeline.sh — Dart Build Pipeline (Docker-native)
#  ไม่ต้องติดตั้ง Dart บนเครื่อง — ใช้ Docker ทั้งหมด
#
#  STAGE 1 : LINT    dart analyze + dart format --set-exit-if-changed
#  STAGE 2 : TEST    dart test
#  STAGE 3 : BUILD   docker build → container image
#  STAGE 4 : DEPLOY  docker run  → container รันจริง
#
#  อ้างอิงจาก pipeline.sh ของ Rust (cargo fmt/clippy/test/build)
# ============================================================

# ─── CONFIG ─────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-dart-web-app}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGISTRY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-dart-web-app}"
HOST_PORT="${HOST_PORT:-8085}"
DART_IMAGE="dart-dev"          # dev image สำหรับ lint/test

# ─── Helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)] $*${NC}"; }
ok()   { echo -e "${GREEN}  ✔ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
die()  { echo -e "${RED}  ✘ $*${NC}"; exit 1; }

# ─── check_docker ───────────────────────────────────────────
check_docker() {
  command -v docker &>/dev/null \
    || die "ไม่พบ Docker — ติดตั้งที่ https://docs.docker.com/get-docker/"
  docker info &>/dev/null \
    || die "Docker daemon ไม่ทำงาน — กรุณาเปิด Docker Desktop"
}

# ─── resolve_image ──────────────────────────────────────────
# สร้างชื่อ image กลาง — ใช้ร่วมกันระหว่าง build และ deploy
resolve_image() {
  if [[ -n "$REGISTRY" ]]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest"
  else
    FULL_IMAGE="${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${IMAGE_NAME}:latest"
  fi
}

# ─── ensure_dev_image ───────────────────────────────────────
# build dev stage ครั้งแรก หรือใช้ cache ถ้ามีแล้ว
ensure_dev_image() {
  if ! docker image inspect "$DART_IMAGE" &>/dev/null; then
    log "  สร้าง dev image ครั้งแรก (dart:stable + pub get)..."
    docker build --target dev -t "$DART_IMAGE" .
    ok "dev image พร้อม"
  else
    log "  ใช้ dev image จาก cache"
  fi
}

# ============================================================
#  STAGE 1 — LINT
#
#  dart format --set-exit-if-changed .
#    ตรวจ code format ตาม Dart style guide
#    เทียบกับ: cargo fmt --check  (Rust)  / gofmt -l  (Go)
#
#  dart analyze .
#    static analysis ตรวจ type error, unused var, deprecated API
#    เทียบกับ: cargo clippy  (Rust)  / go vet  (Go)
# ============================================================
stage_lint() {
  log "STAGE 1/4 — LINT"
  log "  dart format --set-exit-if-changed ."
  log "  dart analyze ."

  ensure_dev_image

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$DART_IMAGE" \
    bash -c "
      echo '>>> dart format --set-exit-if-changed .' && \
      dart format --set-exit-if-changed . && \
      echo '✔ format passed' && \
      echo '>>> dart analyze .' && \
      dart analyze . && \
      echo '✔ analyze passed'
    "

  ok "LINT PASSED"
  echo ""
  echo "  สรุป STAGE 1:"
  echo "  dart format  ← cargo fmt --check  (ตรวจ code style)"
  echo "  dart analyze ← cargo clippy       (ตรวจ bugs/types)"
}

# ============================================================
#  STAGE 2 — TEST
#
#  dart test
#    รัน test ทุกไฟล์ใน test/ directory
#    เทียบกับ: cargo test  (Rust)  / go test ./...  (Go)
#
#  NOTE: ถ้าไม่มีไฟล์ test จะแสดง "No tests ran" = pass
# ============================================================
stage_test() {
  log "STAGE 2/4 — TEST"
  log "  dart test"

  ensure_dev_image

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$DART_IMAGE" \
    bash -c "
      echo '>>> dart test' && \
      dart test && \
      echo '✔ tests passed'
    "

  ok "TEST PASSED"
  echo ""
  echo "  สรุป STAGE 2:"
  echo "  dart test ← cargo test  (รัน unit tests)"
}

# ============================================================
#  STAGE 3 — BUILD & PUBLISH
#
#  docker build --target runtime
#    รัน Dockerfile multi-stage:
#      dev stage     → dart pub get
#      builder stage → dart compile exe main.dart -o app
#      runtime stage → debian-slim + binary เท่านั้น
#
#  ผลลัพธ์คือ container image ที่มีแค่ binary
#  เทียบกับ: cargo build --release → ./target/release/binary
# ============================================================
stage_build() {
  log "STAGE 3/4 — BUILD & PUBLISH"

  resolve_image
  log "  Image : $FULL_IMAGE"

  # build ถึง runtime stage เท่านั้น (ข้าม dev)
  docker build \
    --target runtime \
    -t "$FULL_IMAGE" \
    -t "$LATEST_IMAGE" \
    .

  local size
  size=$(docker image inspect "$LATEST_IMAGE" \
    --format='{{printf "%.1f MB" (div (index .Size) 1048576.0)}}' 2>/dev/null \
    || echo "unknown")

  ok "BUILD SUCCESS: $FULL_IMAGE ($size)"

  # push ถ้ามี REGISTRY
  if [[ -n "$REGISTRY" ]]; then
    log "  PUSH → $REGISTRY"
    docker push "$FULL_IMAGE"
    docker push "$LATEST_IMAGE"
    ok "PUSH SUCCESS"
  else
    warn "ไม่มี REGISTRY — build local (ไม่ push)"
    warn "push ด้วย: REGISTRY=ghcr.io/user ./pipeline.sh build"
  fi

  echo ""
  echo "  สรุป STAGE 3:"
  echo "  docker build --target runtime"
  echo "    dev stage     : dart pub get"
  echo "    builder stage : dart compile exe → native binary (AOT)"
  echo "    runtime stage : debian-slim + binary เท่านั้น"
}

# ============================================================
#  STAGE 4 — DEPLOY
#
#  docker run -v .env:/app/.env:ro
#    mount .env เข้า container แบบ read-only
#    app อ่าน .env ทุก request (hot-reload by mtime cache)
#    แก้ .env บน host → เห็นผลทันทีโดยไม่ต้อง restart
#
#  เทียบกับ: ./target/release/dart-web-app
# ============================================================
stage_deploy() {
  log "STAGE 4/4 — DEPLOY"

  resolve_image
  log "  Image : $FULL_IMAGE"

  # ตรวจว่ามี image
  docker image inspect "$FULL_IMAGE" &>/dev/null \
    || die "ไม่พบ image '$FULL_IMAGE'\nรัน: ./pipeline.sh build ก่อน"

  # ตรวจว่ามี .env
  if [[ ! -f ".env" ]]; then
    warn "ไม่พบ .env — container จะใช้ค่า default"
    warn "สร้าง .env ด้วย: cp .env.example .env"
  fi

  # หยุด container เก่า
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "  หยุด container เก่า: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME"
  fi

  # รัน container ใหม่
  # -v .env:/app/.env:ro  = mount .env read-only
  #                          hot-reload: app อ่านใหม่ทุก request ที่ .env เปลี่ยน
  # --env-file .env       = โหลด HOST/PORT เข้า process env ตอน start
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:8080" \
    -e HOST=0.0.0.0 \
    -e PORT=8080 \
    -e ENV_FILE=/app/.env \
    -v "$(pwd)/.env:/app/.env:ro" \
    --env-file .env \
    --restart unless-stopped \
    "$FULL_IMAGE"

  ok "DEPLOY SUCCESS"
  log "  Container : $CONTAINER_NAME"
  log "  Image     : $FULL_IMAGE"
  log "  URL       : http://localhost:${HOST_PORT}"
  log "  .env      : $(pwd)/.env (hot-reload enabled)"
  echo ""
  echo "  ดู logs   : docker logs -f $CONTAINER_NAME"
  echo "  ทดสอบ    : curl http://localhost:${HOST_PORT}/"
  echo "  แก้ config: vim .env  (เห็นผลทันทีไม่ต้อง restart)"
  echo "  หยุด      : docker stop $CONTAINER_NAME"
  echo ""
  echo "  สรุป STAGE 4:"
  echo "  docker run -v .env:/app/.env:ro ← ./target/release/binary"
  echo "  hot-reload: อ่าน .env ใหม่เมื่อ mtime เปลี่ยน (cache IO)"
}

# ============================================================
#  Usage
# ============================================================
usage() {
  echo ""
  echo -e "${CYAN}วิธีใช้: ./pipeline.sh [stage]${NC}"
  echo ""
  echo "  lint     dart format + dart analyze"
  echo "  test     dart test"
  echo "  build    docker build → container image"
  echo "  deploy   docker run  → container"
  echo "  all      ทุก stage (default)"
  echo ""
  echo "Environment variables:"
  echo "  IMAGE_NAME=dart-web-app   ชื่อ image"
  echo "  TAG=v1.0.0                tag (default: git SHA)"
  echo "  REGISTRY=ghcr.io/user     push registry (optional)"
  echo "  HOST_PORT=8085            port บน host"
  echo "  CONTAINER_NAME=dart-web-app"
  echo ""
  echo "ตัวอย่าง:"
  echo "  ./pipeline.sh                           # รันทุก stage"
  echo "  ./pipeline.sh lint                      # เฉพาะ lint"
  echo "  ./pipeline.sh test                      # เฉพาะ test"
  echo "  ./pipeline.sh build                     # build image"
  echo "  ./pipeline.sh deploy                    # deploy"
  echo "  TAG=v1.0.0 ./pipeline.sh build          # build tag v1.0.0"
  echo "  TAG=v1.0.0 ./pipeline.sh deploy         # deploy v1.0.0"
  echo "  TAG=v0.9.0 ./pipeline.sh deploy         # rollback"
  echo "  HOST_PORT=9000 ./pipeline.sh deploy     # port อื่น"
  echo "  REGISTRY=ghcr.io/user ./pipeline.sh build  # push ด้วย"
  echo ""
}

# ============================================================
#  Main
# ============================================================
main() {
  check_docker

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Dart Build Pipeline  (Docker-native)   ║${NC}"
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
