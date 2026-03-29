#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-php-web-app}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"
REGISTRY="${REGISTRY:-}"
CONTAINER_NAME="${CONTAINER_NAME:-php-web-app}"
HOST_PORT="${HOST_PORT:-8080}"

PHP_IMAGE="php:8.2-cli-alpine"

log() { echo "[`date +%H:%M:%S`] $*"; }
die() { echo "✘ $*"; exit 1; }

resolve_image() {
  if [[ -n "$REGISTRY" ]]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest"
  else
    FULL_IMAGE="${IMAGE_NAME}:${TAG}"
    LATEST_IMAGE="${IMAGE_NAME}:latest"
  fi
}

check_docker() {
  docker info >/dev/null || die "Docker not running"
}

# ============================================================
# STAGE 1 — LINT
# php -l = syntax check
# ============================================================
stage_lint() {
  log "STAGE 1 — LINT"

  docker run --rm -v "$(pwd)":/app -w /app $PHP_IMAGE \
    sh -c '
      echo ">>> php -l index.php" &&
      php -l index.php &&
      echo "✔ syntax ok"
    '
}

# ============================================================
# STAGE 2 — TEST
# ============================================================
stage_test() {
  log "STAGE 2 — TEST"

  docker run --rm -v "$(pwd)":/app -w /app $PHP_IMAGE \
    sh -c '
      echo ">>> basic test" &&
      php -r "
        require \"index.php\";
        if (nowTs() <= 0) exit(1);
        echo \"✔ test passed\n\";
      "
    '
}

# ============================================================
# STAGE 3 — BUILD
# ============================================================
stage_build() {
  log "STAGE 3 — BUILD"

  resolve_image

  docker build -t "$FULL_IMAGE" -t "$LATEST_IMAGE" .

  echo "✔ build success: $FULL_IMAGE"
}

# ============================================================
# STAGE 4 — DEPLOY
# ============================================================
stage_deploy() {
  log "STAGE 4 — DEPLOY"

  resolve_image

  [[ -f ".env" ]] || die ".env not found"

  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  docker run -d \
    --name "$CONTAINER_NAME" \
    -p "${HOST_PORT}:8080" \
    -v "$(pwd)/.env:/app/.env:ro" \
    --env-file .env \
    "$FULL_IMAGE"

  echo "✔ running at http://localhost:$HOST_PORT"
}

main() {
  check_docker

  case "${1:-all}" in
    lint) stage_lint ;;
    test) stage_test ;;
    build) stage_build ;;
    deploy) stage_deploy ;;
    all)
      stage_lint
      stage_test
      stage_build
      stage_deploy
      ;;
    *) echo "usage: ./pipeline.sh [lint|test|build|deploy|all]" ;;
  esac
}

main "$@"