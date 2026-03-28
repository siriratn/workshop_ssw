#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  pipeline.sh — Rust Build Pipeline (ผ่าน Docker)
#  ไม่ต้องติดตั้ง Rust บนเครื่อง — ใช้ Docker ทั้งหมด
#
#  Rust (Cargo)              │  pipeline.sh
#  ──────────────────────────┼──────────────────────────────
#  cargo fmt + clippy        │  stage_lint
#  cargo test                │  stage_test
#  docker build              │  stage_build
#  docker run                │  stage_deploy
# ============================================================

# ─── CONFIG ─────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-rust-web-app}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGISTRY:-}"             # เช่น ghcr.io/myuser — ถ้าว่างจะ build local เท่านั้น
CONTAINER_NAME="${CONTAINER_NAME:-rust-web-app}"
HOST_PORT="${HOST_PORT:-8080}"       # port บน host machine
# RUST_IMAGE="rust:latest"             # image ที่ใช้รัน lint/test
RUST_IMAGE="rust-dev"             # image ที่ใช้รัน lint/test

# ─── Helpers ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)] $*${NC}"; }
ok()   { echo -e "${GREEN}  ✔ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
die()  { echo -e "${RED}  ✘ $*${NC}"; exit 1; }


# ─── ตรวจว่ามี Docker ───────────────────────────────────────
check_docker() {
  command -v docker &>/dev/null || die "ไม่พบ Docker — ติดตั้งที่ https://docs.docker.com/get-docker/"
  docker info &>/dev/null       || die "Docker daemon ไม่ทำงาน — กรุณาเปิด Docker Desktop"
}


ensure_dev_image() {
  if ! docker image inspect "$RUST_IMAGE" &>/dev/null; then
    log "สร้าง dev image (ครั้งแรก)..."
    docker build --target dev -t "$RUST_IMAGE" .
    ok "dev image พร้อมใช้งาน"
  else
    log "ใช้ dev image เดิม (cache)"
  fi
}


# ============================================================
#  STAGE 1 — LINT
#  cargo fmt  = ตรวจ code format      (เทียบ gofmt ของ Go)
#  cargo clippy = static analysis     (เทียบ go vet)
#  รันใน rust:latest container — ไม่ต้องติดตั้ง Rust บนเครื่อง
# ============================================================
stage_lint() {
  log "STAGE 1/4 — LINT (cargo fmt + cargo clippy)"
  
  ensure_dev_image   # เพิ่มตรงนี้
  
  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$RUST_IMAGE" \
    bash -c "
      echo '>>> cargo fmt --check' && \
      cargo fmt --all -- --check && \
      echo '✔ fmt passed' && \
      echo '>>> cargo clippy' && \
      cargo clippy --all-targets --all-features -- -D warnings && \
      echo '✔ clippy passed'
    "

  ok "LINT PASSED"
}

# ============================================================
#  STAGE 2 — TEST
#  cargo test = รัน unit test ทุกตัว
#  --nocapture    = แสดง println! output ระหว่าง test
#  --test-threads = รันทีละ 1 thread (ป้องกัน race บน shared state)
# ============================================================
stage_test() {
  log "STAGE 2/4 — TEST (cargo test)"
 
  ensure_dev_image   #  ใช้ตัวเดียวกัน

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$RUST_IMAGE" \
    bash -c "
      echo '>>> cargo test' && \
      cargo test -- --nocapture --test-threads=1 && \
      echo '✔ tests passed'
    "

  ok "TEST PASSED"
}

# ============================================================
#  STAGE 3 — BUILD IMAGE
#  docker build รัน Dockerfile ที่มี multi-stage:
#    builder stage → cargo build --release → binary
#    runtime stage → debian-slim + binary เท่านั้น
# ============================================================
stage_build() {
  log "STAGE 3/4 — BUILD IMAGE (docker build)"

  # กำหนด full image name
  if [[ -n "$REGISTRY" ]]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest"
  else
    FULL_IMAGE="${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${IMAGE_NAME}:latest"
  fi

  log "  Image : $FULL_IMAGE"

  # build และ tag สองชื่อพร้อมกัน
  docker build \
    -t "$FULL_IMAGE" \
    -t "$LATEST_IMAGE" \
    .

  ok "BUILD SUCCESS: $FULL_IMAGE"

  # แสดงขนาด image
  local size
  size=$(docker image inspect "$LATEST_IMAGE" \
    --format='{{printf "%.1f MB" (div (index .Size) 1048576.0)}}' 2>/dev/null || echo "unknown")
  log "  Image size: $size"

  # push ไป registry (ถ้ากำหนด REGISTRY ไว้)
  if [[ -n "$REGISTRY" ]]; then
    log "  PUSH → $REGISTRY"
    docker push "$FULL_IMAGE"
    docker push "$LATEST_IMAGE"
    ok "PUSH SUCCESS"
  else
    warn "ไม่มี REGISTRY — build local เท่านั้น (ไม่ push)"
    warn "กำหนด registry ด้วย: REGISTRY=ghcr.io/user ./pipeline.sh build"
  fi
}

# ============================================================
#  STAGE 4 — DEPLOY
#  หยุด container เก่า แล้วรัน container ใหม่จาก image ที่ build
#  เทียบกับ: ./target/release/rust-web-app
# ============================================================
stage_deploy() {
  log "STAGE 4/4 — DEPLOY (docker run)"

  # หยุดและลบ container เก่าถ้ามี (ไม่ error ถ้าไม่มี)
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "  หยุด container เก่า: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME"
  fi

  # ตรวจว่า image มีอยู่
  docker image inspect "${IMAGE_NAME}:latest" &>/dev/null \
    || die "ไม่พบ image '${IMAGE_NAME}:latest' — กรุณารัน: ./pipeline.sh build ก่อน"

  # รัน container ใหม่
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:8080" \
    -e HOST=0.0.0.0 \
    -e PORT=8080 \
    -e RUST_LOG=info \
    --restart unless-stopped \
    "${IMAGE_NAME}:latest"

  ok "DEPLOY SUCCESS"
  log "  Container : $CONTAINER_NAME"
  log "  URL       : http://localhost:${HOST_PORT}"
  log ""
  log "  ดู logs   : docker logs -f $CONTAINER_NAME"
  log "  หยุด      : docker stop $CONTAINER_NAME"
}

# ============================================================
#  Usage
# ============================================================
usage() {
  echo ""
  echo -e "${CYAN}วิธีใช้: ./pipeline.sh [stage]${NC}"
  echo ""
  echo "  lint     cargo fmt + clippy       ← cargo check"
  echo "  test     cargo test               ← cargo test"
  echo "  build    docker build image       ← cargo build --release"
  echo "  deploy   docker run container     ← ./target/release/rust"
  echo "  all      ทุก stage (default)"
  echo ""
  echo "Environment variables:"
  echo "  IMAGE_NAME=rust-web-app   ชื่อ Docker image"
  echo "  TAG=abc1234               image tag (default: git short SHA)"
  echo "  REGISTRY=ghcr.io/user     push ไป registry (optional)"
  echo "  HOST_PORT=8080            port บน host machine"
  echo "  CONTAINER_NAME=rust-web-app"
  echo ""
  echo "ตัวอย่าง:"
  echo "  ./pipeline.sh                          # รันทุก stage"
  echo "  ./pipeline.sh lint                     # เฉพาะ lint"
  echo "  ./pipeline.sh test                     # เฉพาะ test"
  echo "  ./pipeline.sh build                    # เฉพาะ build image"
  echo "  ./pipeline.sh deploy                   # เฉพาะ deploy"
  echo "  HOST_PORT=9090 ./pipeline.sh deploy    # deploy บน port 9090"
  echo "  REGISTRY=ghcr.io/user ./pipeline.sh build  # build + push"
  echo ""
}

# ============================================================
#  Main
# ============================================================
main() {
  check_docker

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Rust Build Pipeline  (via Docker)      ║${NC}"
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



