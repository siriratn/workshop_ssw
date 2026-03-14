# Python 3 Web App
Component Overview

| Component               | สิ่งที่ใช้               | รายละเอียด                                                                                   |
| ----------------------- | ------------------------ | -------------------------------------------------------------------------------------------- |
| **Source Code**         | `main.py`                | ไฟล์เดียว ใช้ `http.server`, `json`, `threading` จาก Python Standard Library                 |
| **Package Manager**     | `pip`                    | ติดตั้ง dependency ด้วยคำสั่ง `pip install -r requirements.txt`                              |
| **Dependency File**     | `requirements.txt`       | ระบุ package ที่ต้องการ (ตัวอย่างนี้ใช้เฉพาะ standard library จึงไม่มี dependency เพิ่มเติม) |
| **Application Runtime** | CPython 3.12 Interpreter | Python interpreter จะแปลง `.py` เป็น **bytecode** และรันบน **Python Virtual Machine (PVM)**  |
| **OS Executable**       | `python` binary          | รันโปรแกรมด้วยคำสั่ง `python main.py`                                                        |
                                                              |

Runtime Concept
Client → Python HTTP Server → CPython Interpreter → Python Bytecode → PVM