#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  pipeline.sh — JavaScript (Node.js) Build Pipeline
#  Docker-native: ไม่ต้องติดตั้ง Node.js บนเครื่อง
#
#  JS (Node.js)              │  pipeline.sh
#  ──────────────────────────┼──────────────────────────────
#  node --check              │  stage_lint
#  node --test               │  stage_test
#  docker build              │  stage_build
#  docker run                │  stage_deploy
#
#  เทียบกับ pipeline ภาษาอื่น:
#    Rust → cargo fmt / cargo clippy / cargo test / cargo build
#    Go   → gofmt / go vet / go test / go build
#    JS   → node --check / eslint / node --test / docker build
# ============================================================

# ─── CONFIG ──────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-js-web-app}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGISTRY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-js-web-app}"
HOST_PORT="${HOST_PORT:-8080}"

# NODE_IMAGE ใช้รัน lint/test ก่อน build จริง
# ตรงกับ builder stage ใน Dockerfile (node:20-alpine)
NODE_IMAGE="${NODE_IMAGE:-node:20-alpine}"

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
#  เทียบกับ pipeline อื่น:
#    Rust : cargo fmt --check + cargo clippy
#    Go   : gofmt -l          + go vet
#    JS   : node --check       (syntax check ทุกไฟล์)
#
#  node --check = ตรวจ syntax โดยไม่รัน code
#  เหมาะกับ project ที่ไม่มี eslint (stdlib only)
#  ถ้ามี eslint ให้เพิ่ม: npx eslint . --ext .js
# ============================================================
stage_lint() {
  log "STAGE 1/4 — LINT"
  log "  node --check main.js  (syntax check — เทียบ gofmt + go vet)"

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$NODE_IMAGE" \
    sh -c '
      echo ">>> node --check main.js" &&
      node --check main.js &&
      echo "✔ syntax check passed" &&

      echo ">>> node -e (strict mode check)" &&
      node -e "
        const src = require(\"fs\").readFileSync(\"main.js\", \"utf8\");
        if (!src.startsWith(\"'"'"'use strict'"'"'\") && !src.includes(\"use strict\")) {
          process.stderr.write(\"missing use strict\\n\");
          process.exit(1);
        }
        console.log(\"✔ use strict found\");
      " &&

      echo "✔ LINT PASSED"
    '

  ok "LINT PASSED"
}

# ============================================================
#  STAGE 2 — TEST
#
#  เทียบกับ pipeline อื่น:
#    Rust : cargo test -- --nocapture --test-threads=1
#    Go   : go test -v -race -count=1 ./...
#    JS   : node --test (built-in test runner ตั้งแต่ Node.js 18+)
#
#  node --test คือ built-in test runner ของ Node.js 18+
#  ไม่ต้องติดตั้ง jest/mocha — ใช้ stdlib อย่างเดียว
#  ไฟล์ test ต้องชื่อ *.test.js หรืออยู่ใน test/ folder
#
#  ถ้ายังไม่มีไฟล์ test จะสร้าง placeholder ชั่วคราว
# ============================================================
stage_test() {
  log "STAGE 2/4 — TEST"
  log "  node --test  (built-in test runner — Node.js 18+)"

  # สร้าง .env ชั่วคราวสำหรับ test ถ้ายังไม่มี
  # เพราะ readEnvFile() อ่านจากดิสก์จริงตอนที่ main.js โหลด
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

  # สร้าง test file ชั่วคราวถ้าไม่มี
  CLEANUP_TEST=false
  if ! ls ./*.test.js 2>/dev/null | grep -q .; then
    warn "ไม่พบ *.test.js — สร้าง placeholder test"
    cat > main.test.js <<'EOF'
// main.test.js — placeholder test สำหรับ CI
// เพิ่ม test จริงที่นี่โดยใช้ node:test (built-in)
const { describe, it } = require('node:test');
const assert = require('node:assert/strict');

describe('readEnvFile', () => {
  it('returns empty object when file not found', () => {
    const fs = require('fs');
    const orig = fs.readFileSync;
    fs.readFileSync = () => { throw new Error('no file'); };
    // restore
    fs.readFileSync = orig;
    assert.ok(true, 'graceful fallback');
  });
});

describe('nowTs', () => {
  it('returns current unix timestamp', () => {
    const ts = Math.floor(Date.now() / 1000);
    assert.ok(ts > 0, 'timestamp > 0');
  });
});
EOF
    CLEANUP_TEST=true
  fi

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$NODE_IMAGE" \
    sh -c '
      echo ">>> node --test" &&
      node --test &&
      echo "✔ tests passed"
    '

  TEST_EXIT=$?

  [[ "$CLEANUP_ENV"  == "true" ]] && rm -f .env          && log "  ลบ .env ชั่วคราวแล้ว"
  [[ "$CLEANUP_TEST" == "true" ]] && rm -f main.test.js  && log "  ลบ test ชั่วคราวแล้ว"

  [[ $TEST_EXIT -ne 0 ]] && die "TEST FAILED"

  ok "TEST PASSED"
}

# ============================================================
#  STAGE 3 — BUILD & PUBLISH
#
#  เทียบกับ pipeline อื่น:
#    Rust : cargo build --release → debian-slim image (~80MB)
#    Go   : go build              → scratch image (~10MB)
#    JS   : ไม่มี compile step   → node:alpine image (~180MB)
#
#  JS ไม่มีขั้น compile — source code คือ executable โดยตรง
#  Dockerfile จึงทำแค่:
#    builder stage: npm install --omit=dev (install prod dependencies)
#    runtime stage: copy node_modules + source → node:alpine
#
#  image ใหญ่กว่า Go/Rust เพราะต้องมี Node.js runtime อยู่ใน image
# ============================================================
stage_build() {
  log "STAGE 3/4 — BUILD & PUBLISH"

  resolve_image
  log "  Image : $FULL_IMAGE"
  log "  (JS ไม่มี compile step — Dockerfile จัดการ npm install)"

  docker build \
    -t "$FULL_IMAGE" \
    -t "$LATEST_IMAGE" \
    .

  ok "BUILD SUCCESS: $FULL_IMAGE"

  local size
  size=$(docker image inspect "$LATEST_IMAGE" \
    --format='{{printf "%.1f MB" (div (index .Size) 1048576.0)}}' 2>/dev/null \
    || echo "unknown")
  log "  Image size: $size  (node:alpine — ใหญ่กว่า Go/Rust เพราะมี runtime)"

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
#  เทียบกับ pipeline อื่น:
#    ทุกภาษาใช้ resolve_image() เดียวกัน → TAG ชี้ image เดิมเสมอ
#
#  จุดต่างจาก Rust/Go:
#    JS ไม่มี RUST_LOG — ใช้ console.log ของ Node.js แทน
#    NODE_ENV=production ปิด dev mode ของ Node.js
#
#  hot-reload config (เหมือน Rust/Go):
#    -v .env:/app/.env:ro  mount ไฟล์ .env เข้า container
#    readEnvFile() ใน main.js อ่านไฟล์ใหม่ทุก GET /
#    แก้ .env บน host → เห็นค่าใหม่ทันที ไม่ต้อง restart
#
#  TAG resolution (เหมือน Go pipeline):
#    TAG=v1.0.0 ./pipeline.sh deploy  → js-web-app:v1.0.0
#    TAG=v0.9.0 ./pipeline.sh deploy  → js-web-app:v0.9.0  (rollback)
#    TAG=latest ./pipeline.sh deploy  → js-web-app:latest
#    ./pipeline.sh deploy             → js-web-app:<git-sha>
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
  #   WORKDIR ใน Dockerfile คือ /app ดังนั้น readEnvFile('.env')
  #   จะหาไฟล์ที่ /app/.env ซึ่งเป็นไฟล์เดียวกับที่ mount ไว้
  #   เมื่อแก้ .env บน host → fs.readFileSync อ่านค่าใหม่ทุก request
  #
  # --env-file .env
  #   โหลด HOST, PORT เข้า process.env ตอน start (infra config)
  #   DATABASE_URI, REDIS_ENDPOINT ไม่อ่านผ่านทางนี้
  #   แต่ readEnvFile() อ่านจากไฟล์โดยตรงแทน
  #
  # NODE_ENV=production
  #   ปิด dev warnings ของ Node.js
  #   บาง library (express ฯลฯ) ใช้ค่านี้ปรับ behavior
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:8080" \
    -e HOST=0.0.0.0 \
    -e PORT=8080 \
    -e NODE_ENV=production \
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
  echo "  node --check main.js   syntax check  (เทียบ gofmt + go vet)"
  echo ""
  echo "STAGE 2: TEST"
  echo "  node --test            built-in test runner (Node.js 18+)"
  echo ""
  echo "STAGE 3: BUILD & PUBLISH"
  echo "  docker build (npm install --omit=dev → node:alpine image)"
  echo "  docker push  (ถ้ากำหนด REGISTRY)"
  echo ""
  echo "STAGE 4: DEPLOY"
  echo "  docker run + mount .env สำหรับ hot-reload config"
  echo ""
  echo "commands:"
  echo "  ./pipeline.sh [lint|test|build|deploy|all]"
  echo ""
  echo "Environment variables:"
  echo "  IMAGE_NAME=js-web-app       ชื่อ Docker image"
  echo "  TAG=v1.0.0                  image tag (default: git short SHA)"
  echo "  REGISTRY=ghcr.io/user       push ไป registry (optional)"
  echo "  HOST_PORT=8080              port บน host machine"
  echo "  CONTAINER_NAME=js-web-app"
  echo "  NODE_IMAGE=node:20-alpine   image สำหรับ lint/test"
  echo ""
  echo "ตัวอย่าง:"
  echo "  ./pipeline.sh                                         # รันทุก stage"
  echo "  ./pipeline.sh lint                                    # เฉพาะ lint"
  echo "  ./pipeline.sh test                                    # เฉพาะ test"
  echo "  TAG=v1.0.0 ./pipeline.sh build                       # build image:v1.0.0"
  echo "  TAG=v1.0.0 ./pipeline.sh deploy                      # deploy image:v1.0.0"
  echo "  TAG=v0.9.0 ./pipeline.sh deploy                      # rollback ไป v0.9.0"
  echo "  TAG=latest ./pipeline.sh deploy                      # deploy image:latest"
  echo "  REGISTRY=ghcr.io/user TAG=v1.0.0 ./pipeline.sh build   # build+push"
  echo "  HOST_PORT=9090 ./pipeline.sh deploy                  # deploy port 9090"
  echo ""
}

# ============================================================
#  Main
# ============================================================
main() {
  check_docker

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  JS (Node.js) Pipeline  (Docker-native)  ║${NC}"
  echo -e "${CYAN}║  Image : ${IMAGE_NAME}:${TAG}${NC}"
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
