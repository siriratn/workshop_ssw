
# Component ตามโจทย์
 
| โจทย์ | ไฟล์ | คำอธิบาย |
|-------|------|----------|
| Source Code | `src/main.rs` | โค้ด Rust ทั้งหมด |
| Package Manager | `Cargo.toml` (Cargo) | จัดการ dependencies |
| Dependency File | `Cargo.toml` `[dependencies]` | ระบุ library ที่ใช้ |
| App Runtime | Tokio (async runtime) | รัน event loop |
| App Package / OS Executable | `Dockerfile` (binary) | compile → binary ใน container |

