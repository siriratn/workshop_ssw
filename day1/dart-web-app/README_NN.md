
สร้าง image
```
docker build -t dart-web-app:1.0 .
```

สร้าง container
```
docker run -d \
  --name dart-web-app \
  -p 8080:8080 \
  -v $(pwd)/.env:/app/.env:ro \
  --restart unless-stopped \
  dart-web-app:1.0

  ```