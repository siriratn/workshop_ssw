# Bash Web App – Component Overview

| Component                  | รายละเอียด                                                                                                                                                           |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Source Code**            | `main.sh` เป็น Bash script ไฟล์เดียวที่ใช้ควบคุมการทำงานทั้งหมดของแอปพลิเคชัน และไม่มีการใช้ external library                                                        |
| **Package Manager**        | ไม่มี (N/A) — Bash ไม่มี package manager ของตัวเอง เนื่องจากใช้เครื่องมือที่มาพร้อมกับระบบปฏิบัติการอยู่แล้ว เช่น `nc`, `awk`, `grep`, `sed`, `dd`, `flock`          |
| **Dependency Declaration** | ใช้ `Dockerfile` เป็นตัวกำหนด dependency ของระบบ โดยคำสั่ง `apk add bash netcat-openbsd coreutils util-linux` จะทำหน้าที่ติดตั้งเครื่องมือที่จำเป็นผ่าน Alpine Linux |
| **Application Runtime**    | ใช้ `bash` process เป็น runtime โดย container จะเริ่มทำงานด้วยคำสั่ง `CMD ["bash", "main.sh"]` ซึ่งทำให้ Bash interpreter อ่านและรัน script ทีละบรรทัด               |
| **OS Executable**          | ใช้ `nc` (netcat) ซึ่งเป็น binary ของระบบปฏิบัติการสำหรับรับ TCP connection และทำหน้าที่เป็นตัวรับ request แทน runtime ของภาษาโปรแกรมทั่วไป                          |
