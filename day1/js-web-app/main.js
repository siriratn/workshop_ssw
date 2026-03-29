// main.js
// ============================================================
//  โปรแกรม : Event-Driven Web Application
//  ภาษา    : JavaScript (Node.js)
//  Library  : Standard Library เท่านั้น
//               http    — HTTP server
//               url     — parse URL / path
//               fs      — อ่านไฟล์ .env (เพิ่มใหม่)
//               process — environment variable, graceful shutdown
// ============================================================

'use strict';

const http    = require('http');
const url     = require('url');
const fs      = require('fs');      // [เพิ่มใหม่] อ่านไฟล์ .env
const process = require('process');

// ============================================================
//  [เพิ่มใหม่] Hot-reload config จาก .env
//
//  หลักการ: อ่านไฟล์ .env ใหม่ทุกครั้งที่ถูกเรียก
//  ต่างจาก process.env ตรงที่:
//    process.env.KEY   → set ครั้งเดียวตอน start — เปลี่ยนไม่ได้
//    readEnvFile()     → อ่านจากดิสก์ทุกครั้ง — เห็นการเปลี่ยนแปลงทันที
//
//  Node.js ใช้ fs.readFileSync เพราะ:
//    - อ่านไฟล์เล็กมาก (< 1KB) latency ต่างกันแค่ microsecond
//    - ใช้ sync ใน handler ไม่บล็อก event loop นานพอที่จะกระทบ throughput
//    - ถ้าต้องการ async สามารถเปลี่ยนเป็น fs.promises.readFile() ได้
// ============================================================

/**
 * readEnvFile — อ่านไฟล์ .env แล้วคืน object { KEY: value }
 * รองรับ format:
 *   KEY=value
 *   KEY="value with spaces"
 *   # comment (ข้าม)
 *   บรรทัดว่าง (ข้าม)
 *
 * @param {string} filename - path ของไฟล์ .env
 * @returns {Object.<string, string>}
 */
function readEnvFile(filename = '.env') {
  try {
    const content = fs.readFileSync(filename, 'utf8');
    const result  = {};

    for (const line of content.split('\n')) {
      const trimmed = line.trim();

      // ข้ามบรรทัดว่างและ comment
      if (!trimmed || trimmed.startsWith('#')) continue;

      // แยก KEY=value (ตัดแค่ = ตัวแรก เผื่อ value มี = อยู่)
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx === -1) continue;

      const key = trimmed.slice(0, eqIdx).trim();
      let   val = trimmed.slice(eqIdx + 1).trim();

      // ลบ quote รอบ value ถ้ามี เช่น KEY="value" หรือ KEY='value'
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }

      result[key] = val;
    }

    return result;
  } catch {
    // ไฟล์ไม่มีหรือเปิดไม่ได้ — คืน object ว่าง ไม่ crash
    log('WARN', `cannot read ${filename} — returning empty config`);
    return {};
  }
}

/**
 * loadConfig — อ่าน .env ใหม่ทุกครั้ง แล้วสร้าง config object
 * fallback chain: ค่าใน .env → process.env → string ว่าง
 *
 * @returns {{ database_url: string, redis_endpoint: string }}
 */
function loadConfig() {
  const env = readEnvFile('.env');

  const getVal = (key) =>
    (env[key] && env[key] !== '') ? env[key] : (process.env[key] ?? '');

  return {
    database_url:   getVal('DATABASE_URI'),
    redis_endpoint: getVal('REDIS_ENDPOINT'),
  };
}

// ============================================================
//  Helpers
// ============================================================

const nowTs = () => Math.floor(Date.now() / 1000);

const apiOk  = (message, data) => ({ success: true,  message, data, timestamp: nowTs() });
const apiErr = (message)       => ({ success: false, message, timestamp: nowTs() });

const log = (level, msg) =>
  console.log(`[${new Date().toISOString()}] [${level}] ${msg}`);

// ============================================================
//  In-memory Store
// ============================================================

const store = {
  events:  [],
  counter: 0,

  add(name, payload) {
    this.counter++;
    const event = {
      id:         `evt-${String(this.counter).padStart(4, '0')}`,
      name,
      payload:    payload ?? {},
      created_at: nowTs(),
    };
    this.events.push(event);
    return event;
  },

  listAll()     { return [...this.events]; },

  findById(id)  { return this.events.find(e => e.id === id) ?? null; },

  deleteById(id) {
    const idx = this.events.findIndex(e => e.id === id);
    if (idx === -1) return null;
    return this.events.splice(idx, 1)[0];
  },
};

// ============================================================
//  HTTP Response Helpers
// ============================================================

function sendJson(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type':   'application/json',
    'Content-Length': Buffer.byteLength(json),
  });
  res.end(json);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data',  chunk => chunks.push(chunk));
    req.on('end',   ()    => {
      try {
        const raw = Buffer.concat(chunks).toString('utf8');
        resolve(raw ? JSON.parse(raw) : {});
      } catch {
        reject(new Error('invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

// ============================================================
//  Router
// ============================================================

const ROUTE_EVENT_ID = /^\/events\/([^/]+)$/;

async function router(req, res) {
  const { pathname } = url.parse(req.url);
  const method = req.method;

  log('INFO', `${method} ${pathname}`);

  // ── GET / ─────────────────────────────────────────────────
  // [แก้ไข] เพิ่ม field "config" ใน response
  // loadConfig() อ่านไฟล์ .env ใหม่ทุก request
  // เมื่อแก้ .env บน host → เห็นค่าใหม่ทันทีใน request ถัดไป
  if (method === 'GET' && pathname === '/') {
    const cfg = loadConfig();   // ← อ่านสดทุกครั้ง

    sendJson(res, 200, apiOk('JS Event-Driven Web App is running!', {
      status:  'healthy',
      version: '1.0.0',
      lang:    'javascript',
      config:  cfg,             // ← เพิ่มใหม่
    }));
    return;
  }

  // ── GET /events ───────────────────────────────────────────
  if (method === 'GET' && pathname === '/events') {
    const events = store.listAll();
    sendJson(res, 200, apiOk(`found ${events.length} event(s)`, events));
    return;
  }

  // ── POST /events ──────────────────────────────────────────
  if (method === 'POST' && pathname === '/events') {
    let body;
    try {
      body = await readBody(req);
    } catch {
      sendJson(res, 400, apiErr('invalid JSON body'));
      return;
    }

    const name = (body.name ?? '').trim();
    if (!name) {
      log('WARN', 'rejected — name is empty');
      sendJson(res, 400, apiErr('name cannot be empty'));
      return;
    }

    const event = store.add(name, body.payload);
    log('INFO', `created event id=${event.id} name=${name}`);
    sendJson(res, 201, apiOk('event created successfully', event));
    return;
  }

  // ── /events/{id} ──────────────────────────────────────────
  const match = pathname.match(ROUTE_EVENT_ID);
  if (match) {
    const id = match[1];

    if (method === 'GET') {
      const event = store.findById(id);
      if (!event) {
        sendJson(res, 404, apiErr(`event '${id}' not found`));
      } else {
        sendJson(res, 200, apiOk('event found', event));
      }
      return;
    }

    if (method === 'DELETE') {
      const removed = store.deleteById(id);
      if (!removed) {
        sendJson(res, 404, apiErr(`event '${id}' not found`));
      } else {
        log('INFO', `deleted event id=${id}`);
        sendJson(res, 200, apiOk('event deleted', { deleted_id: id }));
      }
      return;
    }
  }

  sendJson(res, 404, apiErr(`route not found: ${pathname}`));
}

// ============================================================
//  Main — App Runtime (Node.js Event Loop)
// ============================================================

const HOST = process.env.HOST ?? '0.0.0.0';
const PORT = parseInt(process.env.PORT ?? '8080', 10);

const server = http.createServer((req, res) => {
  router(req, res).catch(err => {
    log('ERROR', err.message);
    sendJson(res, 500, apiErr('internal server error'));
  });
});

server.listen(PORT, HOST, () => {
  log('INFO', '=========================================');
  log('INFO', '  JS Event-Driven Web App  v1.0.0');
  log('INFO', `  Listening on http://${HOST}:${PORT}`);
  log('INFO', '=========================================');
});

// Graceful Shutdown
process.on('SIGTERM', () => {
  log('INFO', 'SIGTERM received — shutting down...');
  server.close(() => {
    log('INFO', 'Server closed');
    process.exit(0);
  });
});