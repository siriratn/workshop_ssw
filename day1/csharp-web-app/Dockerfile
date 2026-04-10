# ============================================================
#  Dockerfile — Multi-stage build สำหรับ C# Web App
#
#  Stage dev     : sdk image สำหรับ lint/test (pipeline.sh ใช้)
#  Stage builder : dotnet publish → /publish
#  Stage runtime : aspnet runtime + publish เท่านั้น
# ============================================================

# ── Stage: dev (pipeline.sh ใช้สำหรับ lint และ test) ─────────
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS dev

WORKDIR /app
COPY *.csproj ./
RUN dotnet restore
COPY . .

# ── Stage: builder — compile + publish ───────────────────────
FROM dev AS builder

# dotnet publish = compile + bundle dependencies → /publish
# -c Release    = optimize (เทียบ cargo build --release)
# --no-restore  = ใช้ cache จาก restore ก่อนหน้า
RUN dotnet publish -c Release --no-restore -o /publish

# ── Stage: runtime — minimal image + app เท่านั้น ────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime

WORKDIR /app

COPY --from=builder /publish .

# .env จะถูก mount เข้ามาตอน docker run ผ่าน -v
ENV HOST=0.0.0.0
ENV PORT=8080
ENV ENV_FILE=/app/.env
ENV ASPNETCORE_ENVIRONMENT=Production

EXPOSE 8080

CMD ["dotnet", "csharp-web-app.dll"]
