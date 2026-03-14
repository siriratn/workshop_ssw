# ============================================================
#  Dockerfile — Multi-stage build สำหรับ C# Web App
#  Stage 1 : Builder  — dotnet build + publish
#  Stage 2 : Runtime  — dotnet runtime image (ไม่มี SDK)
# ============================================================

# ── Stage 1: Builder ─────────────────────────────────────────
# sdk image มี dotnet CLI, compiler, NuGet (Package Manager)
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS builder

WORKDIR /app

# Copy Dependency File ก่อน (cache layer)
# dotnet restore จะ download dependencies ตาม .csproj
COPY *.csproj ./
RUN dotnet restore

# Copy Source Code
COPY . ./

# Publish = compile + bundle ทุกอย่างลง /publish
# -c Release    = optimize build
# --no-restore  = ใช้ deps จาก cache ขั้นตอนก่อน
# -o /publish   = output directory
RUN dotnet publish -c Release --no-restore -o /publish

# ── Stage 2: Runtime ─────────────────────────────────────────
# aspnet image มีแค่ ASP.NET Core runtime (ไม่มี SDK/compiler)
# เล็กกว่า sdk image มาก (~200MB vs ~800MB)
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime

WORKDIR /app

# Copy ผลลัพธ์จาก builder (App Package / OS Executable)
COPY --from=builder /publish .

ENV HOST=0.0.0.0
ENV PORT=8080
ENV ASPNETCORE_ENVIRONMENT=Production

EXPOSE 8080

# App Runtime — dotnet เป็น OS Executable ที่รัน .dll
CMD ["dotnet", "csharp-web-app.dll"]
