#!/bin/bash

# ============================================================
#  build.sh — Go Build Pipeline
#  เทียบเท่า Cargo workflow ของ Rust
#
#  Rust (Cargo)              │  Go (script นี้)
#  ──────────────────────────┼─────────────────────────────
#  cargo check               │  go vet + staticcheck
#  cargo test                │  go test ./...
#  cargo build --release     │  go build -ldflags="-s -w"
#  ./target/release/rust     │  ./bin/go-web-app
# ============================================================

set -e  # หยุดทันทีถ้าคำสั่งใดล้มเหลว (exit code != 0)

# ── สีสำหรับ output ──────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color (reset)

# ── Config ───────────────────────────────────────────────────
APP_NAME="go-web-app"
BUILD_DIR="./bin"
BINARY="$BUILD_DIR/$APP_NAME"
MAIN_PKG="."           # path ของ main package
GO_VERSION_MIN="1.22"  # Go version ขั้นต่ำที่รองรับ

# ── Helper functions ─────────────────────────────────────────

# พิมพ์ header แต่ละ step
step() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════${NC}"
}

# พิมพ์ผลสำเร็จ
ok() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

# พิมพ์ข้อมูล
info() {
    echo -e "${BLUE}  → $1${NC}"
}

# พิมพ์ warning
warn() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

# พิมพ์ error แล้วออก
fail() {
    echo -e "${RED}  ✗ $1${NC}"
    exit 1
}

# ── ตรวจสอบ Go ติดตั้งแล้วหรือยัง ───────────────────────────
check_go_installed() {
    if ! command -v go &> /dev/null; then
        fail "ไม่พบ Go — กรุณาติดตั้งที่ https://go.dev/dl/"
    fi

    local version
    version=$(go version | awk '{print $3}' | sed 's/go//')
    info "Go version: $version"
}

# ============================================================
#  STEP 1 — LINT (เทียบกับ cargo check)
#  ตรวจสอบ syntax และ common bugs โดยไม่ต้อง compile จริง
# ============================================================
run_lint() {
    step "STEP 1/4 — LINT  (cargo check)"

    # go vet = static analysis ตรวจ bug patterns ที่ compiler ไม่จับ
    # เช่น Printf format string ผิด, unreachable code, mutex ที่ copy ผิด
    info "Running: go vet ./..."
    if go vet ./...; then
        ok "go vet passed — ไม่พบ bug patterns"
    else
        fail "go vet failed — กรุณาแก้ไขก่อน build"
    fi

    # gofmt = ตรวจว่า code format ถูกต้องตาม Go standard
    # -l = แสดงชื่อไฟล์ที่ format ไม่ถูก (ไม่แก้ไขไฟล์)
    info "Running: gofmt -l ."
    local unformatted
    unformatted=$(gofmt -l .)
    if [ -n "$unformatted" ]; then
        warn "ไฟล์ต่อไปนี้ format ไม่ถูกต้อง (รัน 'gofmt -w .' เพื่อแก้):"
        echo "$unformatted" | while read -r f; do echo "    $f"; done
    else
        ok "gofmt passed — code format ถูกต้องทุกไฟล์"
    fi

    # staticcheck (ถ้าติดตั้งไว้) = linter ขั้นสูงกว่า go vet
    # ตรวจ deprecated API, unused code, performance issues
    if command -v staticcheck &> /dev/null; then
        info "Running: staticcheck ./..."
        if staticcheck ./...; then
            ok "staticcheck passed"
        else
            warn "staticcheck พบปัญหา (ไม่หยุด build)"
        fi
    else
        warn "staticcheck ไม่ได้ติดตั้ง (ข้ามขั้นตอนนี้)"
        info "ติดตั้งด้วย: go install honnef.co/go/tools/cmd/staticcheck@latest"
    fi
}

# ============================================================
#  STEP 2 — UNIT TEST (เทียบกับ cargo test)
#  รัน test ทุกไฟล์ที่ลงท้ายด้วย _test.go
# ============================================================
run_test() {
    step "STEP 2/4 — TEST  (cargo test)"

    # go test ./... = รัน test ทุก package ใน project
    # -v          = verbose แสดงชื่อ test ทุกตัว
    # -race       = ตรวจ race condition (data race detector)
    # -cover      = แสดง code coverage %
    # -timeout    = หยุดถ้า test รันนานเกิน 30 วินาที
    info "Running: go test -v -race -cover -timeout=30s ./..."

    if go test -v -race -cover -timeout=30s ./...; then
        ok "Tests passed"
    else
        fail "Tests failed — กรุณาแก้ไขก่อน build"
    fi

    # NOTE: ถ้าไม่มีไฟล์ _test.go จะแสดง "no test files"
    # ซึ่งถือว่า pass (ไม่ใช่ error)
}

# ============================================================
#  STEP 3 — BUILD (เทียบกับ cargo build --release)
#  compile source code → executable binary
# ============================================================
run_build() {
    step "STEP 3/4 — BUILD  (cargo build --release)"

    # สร้าง output directory
    mkdir -p "$BUILD_DIR"
    info "Output: $BINARY"

    # บันทึก build metadata
    local build_time
    build_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local git_commit
    git_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    info "Build time : $build_time"
    info "Git commit : $git_commit"

    # CGO_ENABLED=0  → static binary (ไม่พึ่ง C library)
    #                  เหมือน Rust ที่ compile เป็น static binary
    # GOOS=linux     → target OS (เปลี่ยนเป็น darwin/windows ได้)
    # GOARCH=amd64   → target architecture
    # -ldflags       → linker flags
    #   -s           = ลบ symbol table (ลด binary size)
    #   -w           = ลบ DWARF debug info (ลด binary size อีก)
    #   -X           = inject ค่าตอน compile time (เหมือน --features ของ Cargo)
    info "Running: go build -ldflags='-s -w' -o $BINARY $MAIN_PKG"

    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
        go build \
        -ldflags="-s -w \
            -X main.BuildTime=$build_time \
            -X main.GitCommit=$git_commit" \
        -o "$BINARY" \
        "$MAIN_PKG"

    # แสดงขนาด binary
    local size
    size=$(du -sh "$BINARY" | cut -f1)
    ok "Build success — binary size: $size"
    ok "Binary location: $BINARY"
}

# ============================================================
#  STEP 4 — DEPLOY / RUN (เทียบกับ ./target/release/rust)
#  รัน binary ที่ build ได้
# ============================================================
run_deploy() {
    step "STEP 4/4 — DEPLOY  (./target/release/rust-web-app)"

    # ตรวจว่ามี binary หรือยัง
    if [ ! -f "$BINARY" ]; then
        fail "ไม่พบ binary '$BINARY' — กรุณารัน build ก่อน"
    fi

    info "Starting: $BINARY"
    info "Port     : ${PORT:-8080}"
    info "กด Ctrl+C เพื่อหยุด"
    echo ""

    # รัน binary (เหมือน ./target/release/rust-web-app)
    HOST="${HOST:-0.0.0.0}" PORT="${PORT:-8080}" "$BINARY"
}

# ============================================================
#  Usage — แสดงวิธีใช้
# ============================================================
usage() {
    echo ""
    echo -e "${CYAN}Go Build Pipeline — build.sh${NC}"
    echo ""
    echo "วิธีใช้:"
    echo "  ./build.sh [command]"
    echo ""
    echo "Commands:"
    echo "  lint     ตรวจสอบ code (go vet + gofmt)    ← cargo check"
    echo "  test     รัน unit tests                    ← cargo test"
    echo "  build    compile เป็น binary               ← cargo build --release"
    echo "  deploy   รัน binary                        ← ./target/release/..."
    echo "  all      รันทุก step ตามลำดับ (default)"
    echo "  clean    ลบ binary และ build artifacts"
    echo ""
    echo "ตัวอย่าง:"
    echo "  ./build.sh            # รันทุก step"
    echo "  ./build.sh lint       # เฉพาะ lint"
    echo "  ./build.sh test       # เฉพาะ test"
    echo "  ./build.sh build      # เฉพาะ build"
    echo "  ./build.sh deploy     # เฉพาะ run"
    echo "  PORT=9090 ./build.sh deploy  # รันที่ port 9090"
    echo ""
}

# ============================================================
#  Clean — ลบ build artifacts
# ============================================================
run_clean() {
    step "CLEAN"
    info "Removing: $BUILD_DIR/"
    rm -rf "$BUILD_DIR"
    info "Removing: go test cache"
    go clean -testcache
    ok "Clean done"
}

# ============================================================
#  Main — รับ argument แล้ว dispatch ไป step ที่ถูกต้อง
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    Go Build Pipeline  v1.0.0         ║${NC}"
    echo -e "${CYAN}║    App: $APP_NAME                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"

    check_go_installed

    local cmd="${1:-all}"

    case "$cmd" in
        lint)    run_lint   ;;
        test)    run_test   ;;
        build)   run_build  ;;
        deploy)  run_deploy ;;
        clean)   run_clean  ;;
        all)
            run_lint
            run_test
            run_build
            run_deploy
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo -e "${RED}  ✗ ไม่รู้จัก command: $cmd${NC}"
            usage
            exit 1
            ;;
    esac

    echo ""
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ Done: $cmd${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo ""
}

main "$@"
