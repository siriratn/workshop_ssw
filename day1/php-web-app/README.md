
## วิธีเรียกใช้ pipeline.sh
``` 
chmod +x pipeline.sh


## STAGE 1 — LINT  
./pipeline.sh lint

# STAGE 2 — TEST   
./pipeline.sh test

# STAGE 3 — BUILD  (docker build image)
./pipeline.sh build

# STAGE 4 — DEPLOY  (docker run container)
./pipeline.sh deploy

# รันทั้งหมด
./pipeline.sh

```
###### ====================================================





| Component               | สิ่งที่ใช้                        | รายละเอียด                                                                                                                      |
| ----------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **Source Code**         | `index.php`                       | ใช้ฟังก์ชันพื้นฐานของ PHP เช่น `$_SERVER`, `file_get_contents`, `json_encode`, `json_decode` สำหรับจัดการ HTTP request/response |
| **Package Manager**     | Composer                          | ใช้ `composer install` สำหรับติดตั้ง dependencies จาก [Packagist](https://packagist.org)                                        |
| **Dependency File**     | `composer.json`                   | ระบุเวอร์ชัน PHP และ dependencies ที่โปรเจกต์ต้องการ                                                                            |
| **Application Runtime** | PHP Interpreter + Built-in Server | ใช้คำสั่ง `php -S host:port` ซึ่งมี event loop สำหรับรับ HTTP request                                                           |
| **OS Executable**       | `php` binary                      | รันแอปด้วยคำสั่ง `php -S ${HOST}:${PORT} index.php` ผ่าน container command                                                      |
