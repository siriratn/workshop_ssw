# ── Stage 1: builder ─────────────────────────
FROM composer:2 AS builder

WORKDIR /app

# copy เฉพาะ composer.json ก่อน
COPY composer.json ./

# ถ้ามี composer.lock ค่อย copy
COPY composer.lock* ./

# install dependencies (รองรับกรณีไม่มี lock)
RUN composer install \
    --no-dev \
    --optimize-autoloader \
    --no-interaction \
    --prefer-dist \
    || true \
 && mkdir -p /app/vendor

# ── Stage 2: runtime ─────────────────────────
FROM php:8.2-cli-alpine

WORKDIR /app

# copy vendor (ถ้ามี)
COPY --from=builder /app/vendor ./vendor

# copy source code
COPY index.php ./

# create data dir
RUN mkdir -p /app/data \
    && chmod 777 /app/data

# env (infra)
ENV HOST=0.0.0.0
ENV PORT=8080

EXPOSE 8080

CMD ["sh", "-c", "php -S ${HOST}:${PORT} index.php"]