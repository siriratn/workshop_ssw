# ============================================================
#  โปรแกรม : Event-Driven Web Application
#  ภาษา    : Python 3
#  Library  : Standard Library เท่านั้น
#               http.server   — HTTP server base class
#               json          — JSON encode/decode
#               threading     — thread-safe lock
#               os            — environment variable
#               time          — timestamp
#               re            — regex สำหรับ path matching
# ============================================================

import http.server   # BaseHTTPRequestHandler, HTTPServer
import json          # dumps, loads
import os            # environ
import re            # compile, match — router
import threading     # Lock — thread-safe store
import time          # time() — unix timestamp


# ============================================================
#  In-memory Store
#  ใช้ list + threading.Lock เพราะ HTTPServer รัน multi-thread
#  (แต่ละ request อาจรันใน thread ของตัวเอง)
# ============================================================

class EventStore:
    def __init__(self):
        self._events: list[dict] = []   # เก็บ event เป็น dict (JSON-friendly)
        self._counter: int = 0
        self._lock = threading.Lock()   # mutex ป้องกัน race condition

    def add(self, name: str, payload: dict) -> dict:
        with self._lock:                # acquire lock ก่อนเขียน
            self._counter += 1
            event = {
                "id":         f"evt-{self._counter:04d}",
                "name":       name,
                "payload":    payload,
                "created_at": int(time.time()),
            }
            self._events.append(event)
            return event

    def list_all(self) -> list[dict]:
        with self._lock:
            return list(self._events)   # คืน copy ป้องกัน mutation

    def find_by_id(self, event_id: str) -> dict | None:
        with self._lock:
            return next((e for e in self._events if e["id"] == event_id), None)

    def delete_by_id(self, event_id: str) -> dict | None:
        with self._lock:
            for i, e in enumerate(self._events):
                if e["id"] == event_id:
                    return self._events.pop(i)   # pop คืน element ที่ลบ
            return None


# Singleton store (shared ระหว่างทุก request)
store = EventStore()


# ============================================================
#  HTTP Response Helpers
# ============================================================

def now_ts() -> int:
    return int(time.time())


def make_response(success: bool, message: str, data=None) -> dict:
    """สร้าง APIResponse dict"""
    resp = {"success": success, "message": message, "timestamp": now_ts()}
    if data is not None:
        resp["data"] = data
    return resp


# ============================================================
#  Request Handler
#  BaseHTTPRequestHandler เรียก do_GET / do_POST / do_DELETE
#  อัตโนมัติเมื่อมี HTTP request เข้ามา — นี่คือ "Event Listener"
# ============================================================

# Pre-compile regex patterns สำหรับ routing
ROUTE_EVENTS    = re.compile(r"^/events$")
ROUTE_EVENT_ID  = re.compile(r"^/events/(?P<id>[^/]+)$")


class EventHandler(http.server.BaseHTTPRequestHandler):

    # ── Logging Override ─────────────────────────────────────
    def log_message(self, fmt, *args):
        """Override ให้ log ออก stdout แทน stderr default"""
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [INFO] {fmt % args}")

    # ── Response Helper ──────────────────────────────────────
    def send_json(self, status: int, data: dict):
        """ส่ง JSON response พร้อม headers"""
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json_body(self) -> dict | None:
        """อ่าน request body ตาม Content-Length แล้ว parse JSON"""
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return None

    # ── Route Dispatcher ─────────────────────────────────────
    # do_GET, do_POST, do_DELETE ถูกเรียกโดย BaseHTTPRequestHandler
    # เมื่อ HTTP event ที่ตรง method เข้ามา

    def do_GET(self):
        if self.path == "/":
            self._handle_index()
        elif ROUTE_EVENTS.match(self.path):
            self._handle_list_events()
        else:
            m = ROUTE_EVENT_ID.match(self.path)
            if m:
                self._handle_get_event(m.group("id"))
            else:
                self.send_json(404, make_response(False, f"route not found: {self.path}"))

    def do_POST(self):
        if ROUTE_EVENTS.match(self.path):
            self._handle_create_event()
        else:
            self.send_json(404, make_response(False, "route not found"))

    def do_DELETE(self):
        m = ROUTE_EVENT_ID.match(self.path)
        if m:
            self._handle_delete_event(m.group("id"))
        else:
            self.send_json(404, make_response(False, "route not found"))

    # ── Handlers ─────────────────────────────────────────────

    def _handle_index(self):
        self.send_json(200, make_response(True,
            "Python Event-Driven Web App is running!",
            {"status": "healthy", "version": "1.0.0", "lang": "python"}
        ))

    def _handle_list_events(self):
        events = store.list_all()
        self.send_json(200, make_response(True,
            f"found {len(events)} event(s)", events))

    def _handle_create_event(self):
        body = self.read_json_body()
        if body is None:
            self.send_json(400, make_response(False, "invalid JSON body"))
            return

        name = (body.get("name") or "").strip()
        if not name:
            print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [WARN] rejected — name is empty")
            self.send_json(400, make_response(False, "name cannot be empty"))
            return

        payload = body.get("payload") or {}
        event = store.add(name, payload)
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [INFO] created event id={event['id']} name={name}")
        self.send_json(201, make_response(True, "event created successfully", event))

    def _handle_get_event(self, event_id: str):
        event = store.find_by_id(event_id)
        if event is None:
            self.send_json(404, make_response(False, f"event '{event_id}' not found"))
            return
        self.send_json(200, make_response(True, "event found", event))

    def _handle_delete_event(self, event_id: str):
        removed = store.delete_by_id(event_id)
        if removed is None:
            self.send_json(404, make_response(False, f"event '{event_id}' not found"))
            return
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [INFO] deleted event id={event_id}")
        self.send_json(200, make_response(True, "event deleted", {"deleted_id": event_id}))


# ============================================================
#  Main — App Runtime
#  ThreadingHTTPServer = สร้าง thread ใหม่ต่อ request
#  (Event-Driven โดย OS จัดการผ่าน thread pool)
# ============================================================

if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))

    # ThreadingMixIn ทำให้รับหลาย request พร้อมกันได้
    class ThreadedHTTPServer(
        http.server.ThreadingHTTPServer
    ):
        pass

    server = ThreadedHTTPServer((host, port), EventHandler)

    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [INFO] ================================")
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [INFO]  Python Event-Driven Web App")
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [INFO]  Listening on http://{host}:{port}")
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [INFO] ================================")

    try:
        server.serve_forever()   # event loop — รอรับ HTTP event ไม่มีสิ้นสุด
    except KeyboardInterrupt:
        print("\n[INFO] Shutting down...")
        server.shutdown()
