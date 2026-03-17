# ============================================================
#  Dockerfile — JavaScript (Node.js) Web App
#  Stage 1 : Builder  — npm install (ไม่มี dep แต่ best practice)
#  Stage 2 : Runtime  — node:alpine + source เท่านั้น
# ============================================================

# ── Stage 1: Builder ─────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Copy Dependency File ก่อน (cache layer)
COPY package.json ./

# Package Manager: npm — install dependencies
RUN npm install --omit=dev

# Copy Source Code
COPY main.js ./

# ── Stage 2: Runtime ─────────────────────────────────────────
FROM node:20-alpine AS runtime

WORKDIR /app

COPY --from=builder /app ./

ENV HOST=0.0.0.0
ENV PORT=8080
ENV NODE_ENV=production

EXPOSE 8080

# App Runtime = node  |  OS Executable = main.js
CMD ["node", "main.js"]
