#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  pipeline.sh — C# Build Pipeline (Docker-native)
#  ไม่ต้องติดตั้ง .NET บนเครื่อง — ใช้ Docker ทั้งหมด
#
#  Rust (Cargo)        │  C# (.NET)          │  pipeline.sh
#  ────────────────────┼─────────────────────┼──────────────
#  cargo fmt --check   │  dotnet format       │  stage_lint
#  cargo clippy        │  dotnet build -w err │  stage_lint
#  cargo test          │  dotnet test         │  stage_test
#  cargo build release │  dotnet publish      │  stage_build
#  ./target/release/.. │  docker run          │  stage_deploy
# ============================================================

# ─── CONFIG ─────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-csharp-web-app}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGISTRY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-csharp-web-app}"
HOST_PORT="${HOST_PORT:-8080}"
DOTNET_DEV_IMAGE="csharp-dev"   # dev image สำหรับ lint/test

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
# ผลลัพธ์: FULL_IMAGE, LATEST_IMAGE (global vars)
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
  if ! docker image inspect "$DOTNET_DEV_IMAGE" &>/dev/null; then
    log "  สร้าง dev image ครั้งแรก (dotnet sdk + restore)..."
    docker build --target dev -t "$DOTNET_DEV_IMAGE" .
    ok "dev image พร้อม"
  else
    log "  ใช้ dev image จาก cache"
  fi
}

# ============================================================
#  STAGE 1 — LINT
#
#  dotnet format --verify-no-changes
#    ตรวจ code format ตาม .editorconfig / Roslyn style
#    เทียบกับ: cargo fmt --check  (Rust)
#              gofmt -l .         (Go)
#              dart format --set-exit-if-changed (Dart)
#
#  dotnet build -warnaserror
#    compile และ treat warnings เป็น errors
#    เทียบกับ: cargo clippy -- -D warnings  (Rust)
#              go vet ./...                  (Go)
# ============================================================
stage_lint() {
  log "STAGE 1/4 — LINT"
  log "  dotnet format --verify-no-changes"
  log "  dotnet build -warnaserror"

  ensure_dev_image

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$DOTNET_DEV_IMAGE" \
    bash -c "
      echo '>>> dotnet format --verify-no-changes' && \
      dotnet format --verify-no-changes && \
      echo '✔ format passed' && \
      echo '>>> dotnet build -warnaserror' && \
      dotnet build -c Release --no-restore -warnaserror && \
      echo '✔ build (lint) passed'
    "

  ok "LINT PASSED"
  echo ""
  echo "  สรุป STAGE 1: LINT"
  echo "  ┌─────────────────────────────────────────────────┐"
  echo "  │ dotnet format --verify-no-changes               │"
  echo "  │   ตรวจ code style (indent, spacing, braces)     │"
  echo "  │   เทียบกับ: cargo fmt --check                   │"
  echo "  │                                                  │"
  echo "  │ dotnet build -warnaserror                       │"
  echo "  │   compile + treat warnings เป็น errors          │"
  echo "  │   เทียบกับ: cargo clippy -- -D warnings         │"
  echo "  └─────────────────────────────────────────────────┘"
}

# ============================================================
#  STAGE 2 — TEST
#
#  dotnet test
#    รัน unit test ทุกไฟล์ใน *Tests/ หรือ *Test.cs
#    เทียบกับ: cargo test  (Rust)
#              go test ./... (Go)
#
#  NOTE: Project นี้ไม่มี test project → "No test projects found"
#        ถือว่า pass (เหมือน go test "no test files")
#        สร้าง test project ด้วย: dotnet new xunit -n AppTests
# ============================================================
stage_test() {
  log "STAGE 2/4 — TEST"
  log "  dotnet test --no-build"

  ensure_dev_image

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$DOTNET_DEV_IMAGE" \
    bash -c "
      echo '>>> dotnet test' && \
      dotnet test --no-build -c Release 2>&1 | tee /tmp/test_out.txt || true && \
      if grep -q 'error\|Error\|FAILED' /tmp/test_out.txt; then
        echo '✘ tests failed'; exit 1
      fi && \
      echo '✔ tests passed (or no test projects found)'
    "

  ok "TEST PASSED"
  echo ""
  echo "  สรุป STAGE 2: TEST"
  echo "  ┌─────────────────────────────────────────────────┐"
  echo "  │ dotnet test --no-build                          │"
  echo "  │   รัน unit tests ทุกไฟล์ *Test.cs              │"
  echo "  │   เทียบกับ: cargo test                          │"
  echo "  │                                                  │"
  echo "  │ เพิ่ม test project:                             │"
  echo "  │   dotnet new xunit -n AppTests                  │"
  echo "  └─────────────────────────────────────────────────┘"
}

# ============================================================
#  STAGE 3 — BUILD & PUBLISH → Container Image
#
#  docker build --target runtime
#    รัน Dockerfile multi-stage:
#      dev stage     → dotnet restore
#      builder stage → dotnet publish -c Release → /publish
#      runtime stage → aspnet:8.0 + /publish เท่านั้น
#
#  เทียบกับ: cargo build --release → ./target/release/binary
# ============================================================
stage_build() {
  log "STAGE 3/4 — BUILD & PUBLISH → Container Image"

  resolve_image
  log "  Image : $FULL_IMAGE"

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
  echo "  สรุป STAGE 3: BUILD & PUBLISH"
  echo "  ┌─────────────────────────────────────────────────┐"
  echo "  │ docker build --target runtime                   │"
  echo "  │   dev stage     : dotnet restore                │"
  echo "  │   builder stage : dotnet publish -c Release     │"
  echo "  │   runtime stage : aspnet:8.0 + /publish         │"
  echo "  │                                                  │"
  echo "  │ ผลลัพธ์: container image พร้อม deploy           │"
  echo "  │ เทียบกับ: cargo build --release                 │"
  echo "  └─────────────────────────────────────────────────┘"
}

# ============================================================
#  STAGE 4 — DEPLOY → Docker run
#
#  docker run -v .env:/app/.env:ro
#    mount .env read-only เข้า container
#    C# อ่าน .env ทุก request โดยตรวจ LastWriteTimeUtc (mtime cache)
#    แก้ .env บน host → เห็นผลทันทีที่ GET / โดยไม่ restart
#
#  เทียบกับ: ./target/release/csharp-web-app
# ============================================================
stage_deploy() {
  log "STAGE 4/4 — DEPLOY → Docker run"

  resolve_image
  log "  Image : $FULL_IMAGE"

  docker image inspect "$FULL_IMAGE" &>/dev/null \
    || die "ไม่พบ image '$FULL_IMAGE'\nรัน: ./pipeline.sh build ก่อน"

  [[ ! -f ".env" ]] && warn "ไม่พบ .env — container จะใช้ค่า default"

  # หยุด container เก่า
  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "  หยุด container เก่า: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME"
  fi

  # รัน container ใหม่
  # -v .env:/app/.env:ro  = mount .env read-only → hot-reload
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
  log "  .env      : $(pwd)/.env (hot-reload by mtime)"
  echo ""
  echo "  ดู logs   : docker logs -f $CONTAINER_NAME"
  echo "  ทดสอบ    : curl http://localhost:${HOST_PORT}/"
  echo "  แก้ config: vim .env  (เห็นผลทันทีไม่ต้อง restart)"
  echo "  หยุด      : docker stop $CONTAINER_NAME"
  echo ""
  echo "  สรุป STAGE 4: DEPLOY"
  echo "  ┌─────────────────────────────────────────────────┐"
  echo "  │ docker run -v .env:/app/.env:ro                 │"
  echo "  │   mount .env read-only                          │"
  echo "  │   hot-reload: C# ตรวจ mtime ทุก GET /          │"
  echo "  │   เทียบกับ: ./target/release/binary             │"
  echo "  └─────────────────────────────────────────────────┘"
}

# ============================================================
#  Usage
# ============================================================
usage() {
  echo ""
  echo -e "${CYAN}วิธีใช้: ./pipeline.sh [stage]${NC}"
  echo ""
  echo "  lint     dotnet format + dotnet build -warnaserror"
  echo "  test     dotnet test"
  echo "  build    docker build → container image"
  echo "  deploy   docker run  → container"
  echo "  all      ทุก stage (default)"
  echo ""
  echo "Environment variables:"
  echo "  IMAGE_NAME=csharp-web-app  ชื่อ image"
  echo "  TAG=v1.0.0                 tag (default: git SHA)"
  echo "  REGISTRY=ghcr.io/user      push registry (optional)"
  echo "  HOST_PORT=8083             port บน host"
  echo "  CONTAINER_NAME=csharp-web-app"
  echo ""
  echo "ตัวอย่าง:"
  echo "  ./pipeline.sh                           # รันทุก stage"
  echo "  ./pipeline.sh lint                      # เฉพาะ lint"
  echo "  ./pipeline.sh test                      # เฉพาะ test"
  echo "  ./pipeline.sh build                     # build image"
  echo "  ./pipeline.sh deploy                    # deploy"
  echo "  TAG=v1.0.0 ./pipeline.sh build          # build v1.0.0"
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
  echo -e "${CYAN}║   C# Build Pipeline  (Docker-native)     ║${NC}"
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
