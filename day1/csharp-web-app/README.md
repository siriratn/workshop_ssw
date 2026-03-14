# C# Web App (.NET 8 Minimal API)
Component Overview


| Component               | สิ่งที่ใช้              | รายละเอียด                                                         |
| ----------------------- | ----------------------- | ------------------------------------------------------------------ |
| **Source Code**         | `Program.cs`            | ใช้ **Minimal API** ของ .NET 8 ไม่ต้องสร้าง Controller class       |
| **Package Manager**     | `dotnet CLI + NuGet`    | ใช้ `dotnet restore` สำหรับดาวน์โหลด dependency จาก NuGet registry |
| **Dependency File**     | `csharp-web-app.csproj` | ไฟล์ XML ที่ระบุ `TargetFramework` และ dependencies                |
| **Application Runtime** | .NET 8 Runtime (CLR)    | **Common Language Runtime** แปลง **IL bytecode → machine code**    |
| **OS Executable**       | `dotnet` binary         | รันด้วยคำสั่ง `dotnet csharp-web-app.dll`                          |
                                    |



Runtime Concept
Client → ASP.NET Minimal API → .NET Runtime (CLR) → JIT Compilation → Machine Code