# ============================================================
#  Dockerfile — PHP Web App
#  ใช้ PHP built-in web server (-S) เพื่อไม่ต้องมี Apache/Nginx
# ============================================================

FROM php:8.2-cli-alpine

WORKDIR /app

# ติดตั้ง composer (Package Manager)
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Copy Dependency File
COPY composer.json ./

# composer install — กรณีนี้ไม่มี external dep
RUN composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null || true

# Copy Source Code
COPY index.php ./

# สร้าง folder สำหรับเก็บ php_events.json และ php_counter.txt
RUN mkdir -p /app/data && chmod 777 /app/data

ENV HOST=0.0.0.0
ENV PORT=8080

EXPOSE 8080

# App Runtime = php binary
# -S = built-in web server (event-driven per request)
# index.php = router script (OS Executable)
CMD ["sh", "-c", "php -S ${HOST}:${PORT} index.php"]
