// ============================================================
//  โปรแกรม : Event-Driven Web Application
//  ภาษา    : JavaScript (Node.js)
//  Library  : Standard Library เท่านั้น
//               http    — HTTP server
//               url     — parse URL / path
//               process — environment variable, graceful shutdown
// ============================================================

'use strict';

const http    = require('http');    // HTTP server (built-in)
const url     = require('url');     // URL parsing (built-in)
const process = require('process'); // env vars, signals (built-in)

// ============================================================
//  Helpers
// ============================================================

const nowTs = () => Math.floor(Date.now() / 1000);

const apiOk = (message, data) => ({
  success: true, message, data, timestamp: nowTs(),
});

const apiErr = (message) => ({
  success: false, message, timestamp: nowTs(),
});

// log ออก stdout พร้อม timestamp
const log = (level, msg) =>
  console.log(`[${new Date().toISOString()}] [${level}] ${msg}`);

// ============================================================
//  In-memory Store
//  Node.js รัน single-threaded event loop
//  ไม่มี race condition จาก multi-thread เลย
//  (เหมือน Dart) แต่ async I/O ยังทำงาน concurrently ผ่าน event loop
// ============================================================

const store = {
  events: [],
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

  listAll() {
    return [...this.events]; // spread = shallow copy
  },

  findById(id) {
    return this.events.find(e => e.id === id) ?? null;
  },

  deleteById(id) {
    const idx = this.events.findIndex(e => e.id === id);
    if (idx === -1) return null;
    return this.events.splice(idx, 1)[0]; // splice คืน array → [0]
  },
};

// ============================================================
//  HTTP Response Helper
// ============================================================

function sendJson(res, status, body) {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type':   'application/json',
    'Content-Length': Buffer.byteLength(json), // byte จริง (รองรับ UTF-8)
  });
  res.end(json);
}

// อ่าน request body แบบ Promise (event-driven)
// Node.js HTTP request เป็น Readable Stream
// ต้องฟัง event 'data' และ 'end' เพื่อรวม chunks
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));  // event: data chunk เข้า
    req.on('end',  ()    => {                     // event: body จบแล้ว
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
  if (method === 'GET' && pathname === '/') {
    sendJson(res, 200, apiOk('JS Event-Driven Web App is running!', {
      status: 'healthy', version: '1.0.0', lang: 'javascript',
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
      body = await readBody(req); // await Promise — non-blocking
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
//  http.createServer สร้าง server ที่ฟัง 'request' event
//  ทุก HTTP request = event ที่ถูก emit เข้า event loop ของ Node.js
// ============================================================

const HOST = process.env.HOST ?? '0.0.0.0';
const PORT = parseInt(process.env.PORT ?? '8080', 10);

// createServer รับ callback = handler สำหรับ 'request' event
const server = http.createServer((req, res) => {
  // router เป็น async function
  // ต้องจับ error ที่อาจเกิดขึ้นใน promise chain
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

// Graceful Shutdown — รับ SIGTERM จาก Docker stop
process.on('SIGTERM', () => {
  log('INFO', 'SIGTERM received — shutting down...');
  server.close(() => {
    log('INFO', 'Server closed');
    process.exit(0);
  });
});
