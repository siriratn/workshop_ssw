#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  pipeline.sh — Python Build Pipeline (Docker-native)
#  ไม่ต้องติดตั้ง Python บนเครื่อง — ใช้ Docker ทั้งหมด
#
#  Python (toolchain)        │  pipeline.sh
#  ──────────────────────────┼──────────────────────────────
#  pyflakes + py_compile     │  stage_lint
#  unittest discover         │  stage_test
#  docker build (multi-stage)│  stage_build
#  docker run                │  stage_deploy
#
#  เทียบกับ pipeline ภาษาอื่น:
#    Rust → cargo fmt / cargo clippy / cargo test / cargo build
#    Go   → gofmt / go vet / go test / go build
#    JS   → node --check / node --test / docker build
#    Py   → pyflakes / py_compile / unittest / docker build
# ============================================================

# ─── CONFIG ──────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-python-web-app}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGISTRY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-python-web-app}"
HOST_PORT="${HOST_PORT:-8080}"

# PYTHON_IMAGE ใช้รัน lint/test ก่อน build จริง
# ตรงกับ base image ใน Dockerfile (python:3.12-slim)
PYTHON_IMAGE="${PYTHON_IMAGE:-python:3.12-slim}"

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
#    Rust : cargo fmt --check  + cargo clippy
#    Go   : gofmt -l           + go vet
#    JS   : node --check
#    Py   : py_compile (syntax) + pyflakes (static analysis)
#
#  py_compile  = ตรวจ Python syntax โดยไม่รัน code
#                เทียบกับ node --check / gofmt
#  pyflakes    = static analysis ตรวจ undefined names,
#                unused imports — เทียบกับ go vet / cargo clippy
#                (stdlib-only ไม่ต้องติดตั้ง เพราะมีใน pip)
# ============================================================
stage_lint() {
  log "STAGE 1/4 — LINT"
  log "  python -m py_compile  (syntax check — เทียบ gofmt / node --check)"
  log "  python -m pyflakes    (static analysis — เทียบ go vet / cargo clippy)"

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$PYTHON_IMAGE" \
    sh -c '
      echo ">>> python -m py_compile main.py" &&
      python -m py_compile main.py &&
      echo "✔ syntax check passed" &&

      echo ">>> pip install pyflakes -q" &&
      pip install pyflakes --quiet &&

      echo ">>> python -m pyflakes main.py" &&
      python -m pyflakes main.py &&
      echo "✔ pyflakes passed"
    '

  ok "LINT PASSED"
}

# ============================================================
#  STAGE 2 — TEST
#
#  เทียบกับ pipeline อื่น:
#    Rust : cargo test -- --nocapture --test-threads=1
#    Go   : go test -v -race -count=1 ./...
#    JS   : node --test
#    Py   : python -m unittest discover
#
#  python -m unittest discover คือ built-in test runner
#  ค้นหาไฟล์ test_*.py หรือ *_test.py อัตโนมัติ
#  ไม่ต้องติดตั้ง pytest (stdlib only)
#
#  -v = verbose แสดงชื่อ test ทุกตัว (เทียบ -v ของ go test)
#  สร้าง .env ชั่วคราวถ้าไม่มี เพราะ read_env_file() อ่านจากดิสก์จริง
# ============================================================
stage_test() {
  log "STAGE 2/4 — TEST"
  log "  python -m unittest discover -v"

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

  # สร้าง test file ชั่วคราวถ้าไม่มี
  CLEANUP_TEST=false
  if ! ls ./test_*.py 2>/dev/null | grep -q .; then
    warn "ไม่พบ test_*.py — สร้าง placeholder test"
    cat > test_main.py <<'TESTEOF'
import sys
import os
import time
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

with patch("http.server.ThreadingHTTPServer", MagicMock()):
    import main as app


class TestReadEnvFile(unittest.TestCase):

    def test_missing_file_returns_empty_dict(self):
        result = app.read_env_file("nonexistent_xyz_99.env")
        self.assertIsInstance(result, dict)
        self.assertEqual(result, {})

    def test_parses_key_value(self):
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as f:
            f.write("DATABASE_URI=postgres://localhost/db\n")
            f.write("REDIS_ENDPOINT=redis://localhost:6379\n")
            f.write("# comment\n")
            name = f.name
        try:
            result = app.read_env_file(name)
            self.assertEqual(result["DATABASE_URI"], "postgres://localhost/db")
            self.assertEqual(result["REDIS_ENDPOINT"], "redis://localhost:6379")
        finally:
            os.unlink(name)

    def test_strips_quotes(self):
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as f:
            f.write('KEY="quoted value"\n')
            name = f.name
        try:
            result = app.read_env_file(name)
            self.assertEqual(result["KEY"], "quoted value")
        finally:
            os.unlink(name)


class TestMakeResponse(unittest.TestCase):

    def test_success_has_required_keys(self):
        resp = app.make_response(True, "ok", {"x": 1})
        self.assertTrue(resp["success"])
        self.assertEqual(resp["message"], "ok")
        self.assertIn("timestamp", resp)
        self.assertIn("data", resp)

    def test_error_has_no_data_key(self):
        resp = app.make_response(False, "err")
        self.assertFalse(resp["success"])
        self.assertNotIn("data", resp)

    def test_timestamp_is_recent(self):
        before = int(time.time())
        resp = app.make_response(True, "t")
        after = int(time.time())
        self.assertGreaterEqual(resp["timestamp"], before)
        self.assertLessEqual(resp["timestamp"], after)


class TestLoadConfig(unittest.TestCase):

    def test_returns_expected_keys(self):
        cfg = app.load_config()
        self.assertIn("database_url",   cfg)
        self.assertIn("redis_endpoint", cfg)


if __name__ == "__main__":
    unittest.main()
TESTEOF
    CLEANUP_TEST=true
  fi

  docker run --rm \
    -v "$(pwd)":/app \
    -w /app \
    "$PYTHON_IMAGE" \
    sh -c '
      echo ">>> python -m unittest discover -v" &&
      python -m unittest discover -v &&
      echo "✔ tests passed"
    '

  TEST_EXIT=$?

  [[ "$CLEANUP_ENV"  == "true" ]] && rm -f .env          && log "  ลบ .env ชั่วคราวแล้ว"
  [[ "$CLEANUP_TEST" == "true" ]] && rm -f test_main.py  && log "  ลบ test ชั่วคราวแล้ว"

  [[ $TEST_EXIT -ne 0 ]] && die "TEST FAILED"

  ok "TEST PASSED"
}

# ============================================================
#  STAGE 3 — BUILD & PUBLISH
#
#  เทียบกับ pipeline อื่น:
#    Rust : cargo build --release → debian-slim + binary  (~80MB)
#    Go   : go build              → scratch + binary      (~10MB)
#    JS   : npm install           → node:alpine + source  (~180MB)
#    Py   : pip install           → python:slim + source  (~150MB)
#
#  Python ไม่มีขั้น compile — Dockerfile ทำแค่ pip install ใน builder
#  แล้ว copy site-packages ไป runtime stage
#
#  tag สองชื่อพร้อมกัน:
#    <image>:<TAG>    เช่น python-web-app:v1.0.0
#    <image>:latest
# ============================================================
stage_build() {
  log "STAGE 3/4 — BUILD & PUBLISH"

  resolve_image
  log "  Image : $FULL_IMAGE"
  log "  (Python multi-stage: pip install → python:slim runtime)"

  docker build \
    -t "$FULL_IMAGE" \
    -t "$LATEST_IMAGE" \
    .

  ok "BUILD SUCCESS: $FULL_IMAGE"

  local size
  size=$(docker image inspect "$LATEST_IMAGE" \
    --format='{{printf "%.1f MB" (div (index .Size) 1048576.0)}}' 2>/dev/null \
    || echo "unknown")
  log "  Image size: $size  (python:slim — ต้องมี interpreter อยู่ใน image)"

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
#    Python ไม่มี RUST_LOG — ใช้ print() ของ stdlib แทน
#    PYTHONUNBUFFERED=1 บังคับให้ log flush ทันทีใน docker logs
#
#  hot-reload config (เหมือน Rust/Go/JS):
#    -v .env:/app/.env:ro  mount ไฟล์ .env เข้า container
#    read_env_file() ใน main.py อ่านไฟล์ใหม่ทุก GET /
#    แก้ DATABASE_URI ใน .env บน host → เห็นค่าใหม่ทันที
#
#  TAG resolution:
#    TAG=v1.0.0 ./pipeline.sh deploy  → python-web-app:v1.0.0
#    TAG=v0.9.0 ./pipeline.sh deploy  → python-web-app:v0.9.0  (rollback)
#    TAG=latest ./pipeline.sh deploy  → python-web-app:latest
#    ./pipeline.sh deploy             → python-web-app:<git-sha>
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
  #   WORKDIR ใน Dockerfile คือ /app ดังนั้น read_env_file('.env')
  #   จะหาไฟล์ที่ /app/.env ซึ่งคือไฟล์ที่ mount ไว้
  #   เมื่อแก้ .env บน host → open() อ่านค่าใหม่ทุก request
  #
  # --env-file .env
  #   โหลด HOST, PORT เข้า os.environ ตอน start (infra config)
  #   DATABASE_URI, REDIS_ENDPOINT ไม่อ่านผ่านทางนี้
  #   แต่ read_env_file() อ่านจากไฟล์โดยตรงแทน
  #
  # PYTHONUNBUFFERED=1
  #   บังคับ Python flush stdout ทันที ไม่งั้น docker logs จะว่างเปล่า
  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:8080" \
    -e HOST=0.0.0.0 \
    -e PORT=8080 \
    -e PYTHONUNBUFFERED=1 \
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
  echo "  python -m py_compile main.py   syntax check    (เทียบ gofmt / node --check)"
  echo "  python -m pyflakes   main.py   static analysis (เทียบ go vet / cargo clippy)"
  echo ""
  echo "STAGE 2: TEST"
  echo "  python -m unittest discover -v  (built-in test runner)"
  echo ""
  echo "STAGE 3: BUILD & PUBLISH"
  echo "  docker build (multi-stage: pip install → python:slim runtime)"
  echo "  docker push  (ถ้ากำหนด REGISTRY)"
  echo ""
  echo "STAGE 4: DEPLOY"
  echo "  docker run + mount .env สำหรับ hot-reload config"
  echo ""
  echo "commands:"
  echo "  ./pipeline.sh [lint|test|build|deploy|all]"
  echo ""
  echo "Environment variables:"
  echo "  IMAGE_NAME=python-web-app     ชื่อ Docker image"
  echo "  TAG=v1.0.0                    image tag (default: git short SHA)"
  echo "  REGISTRY=ghcr.io/user         push ไป registry (optional)"
  echo "  HOST_PORT=8080                port บน host machine"
  echo "  CONTAINER_NAME=python-web-app"
  echo "  PYTHON_IMAGE=python:3.12-slim image สำหรับ lint/test"
  echo ""
  echo "ตัวอย่าง:"
  echo "  ./pipeline.sh                                          # รันทุก stage"
  echo "  ./pipeline.sh lint                                     # เฉพาะ lint"
  echo "  ./pipeline.sh test                                     # เฉพาะ test"
  echo "  TAG=v1.0.0 ./pipeline.sh build                        # build image:v1.0.0"
  echo "  TAG=v1.0.0 ./pipeline.sh deploy                       # deploy image:v1.0.0"
  echo "  TAG=v0.9.0 ./pipeline.sh deploy                       # rollback ไป v0.9.0"
  echo "  TAG=latest ./pipeline.sh deploy                       # deploy image:latest"
  echo "  REGISTRY=ghcr.io/user TAG=v1.0.0 ./pipeline.sh build    # build+push"
  echo "  HOST_PORT=9090 ./pipeline.sh deploy                   # deploy port 9090"
  echo ""
}

# ============================================================
#  Main
# ============================================================
main() {
  check_docker

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  Python Pipeline  (Docker-native)        ║${NC}"
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
