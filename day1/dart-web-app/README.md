
## วิธีเรียกใช้ pipeline.sh
``` 
cd dart-web-app 

chmod +x pipeline.sh


## STAGE 1 — LINT  
./pipeline.sh lint

# STAGE 2 — TEST   
./pipeline.sh test

# STAGE 3 — BUILD  (docker build image)
./pipeline.sh build

# STAGE 4 — DEPLOY  (docker run container)
./pipeline.sh deploy



```



| Component               | สิ่งที่ใช้                | รายละเอียด                                                                                                          |
| ----------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| **Source Code**         | `main.dart`               | ใช้ library มาตรฐาน เช่น `dart:io`, `dart:convert`, `dart:async` สำหรับสร้าง HTTP server และจัดการ request/response |
| **Package Manager**     | `pub` (dart pub)          | ใช้ `dart pub get` สำหรับติดตั้ง dependencies จาก [pub.dev](https://pub.dev)                                        |
| **Dependency File**     | `pubspec.yaml`            | ระบุเวอร์ชัน SDK และ dependencies ของโปรเจกต์                                                                       |
| **Application Runtime** | Dart VM / AOT Binary      | สามารถรันผ่าน Dart VM หรือ compile เป็น **AOT (Ahead-of-Time)** เพื่อให้เป็น native binary                          |
| **OS Executable**       | `./app` (compiled binary) | ใช้คำสั่ง `dart compile exe` เพื่อสร้าง executable ที่รันได้โดยไม่ต้องใช้ VM                                        |
| **Container Command**   | `CMD ["./app"]`           | รัน binary ได้ทันทีบน base image เช่น `debian-slim`                                                                 |
