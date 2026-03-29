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



```
###### ====================================================



| Component               | สิ่งที่ใช้                | รายละเอียด                                                                                            |
| ----------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------- |
| **Source Code**         | `main.js`                 | ใช้ built-in modules เช่น `http`, `url`, `process` สำหรับสร้าง HTTP server และจัดการ request/response |
| **Package Manager**     | `npm`                     | ใช้ `npm install` สำหรับติดตั้ง dependencies จาก npm registry                                         |
| **Dependency File**     | `package.json`            | ระบุชื่อโปรเจกต์ เวอร์ชัน และ dependencies                                                            |
| **Application Runtime** | Node.js (V8 Engine)       | ใช้ **event loop** และ **V8 JavaScript Engine** ในการแปลง JavaScript → machine code                   |
| **OS Executable**       | `node` binary             | รันแอปด้วยคำสั่ง `node main.js`                                                                       |
| **Container Command**   | `CMD ["node", "main.js"]` | ใช้สำหรับรันแอปใน container                                                                           |
