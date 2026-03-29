# ============================================================
#  โปรแกรม : Event-Driven Web Application
#  ภาษา    : Python 3
#  Library  : Standard Library เท่านั้น
# ============================================================

import http.server
import json
import os
import re
import threading
import time


# ============================================================
#  [เพิ่มใหม่] Hot-reload config จาก .env
#
#  หลักการ: อ่านไฟล์ .env ใหม่ทุกครั้งที่ถูกเรียก
#  ต่างจาก os.environ ตรงที่:
#    os.environ['KEY']  → set ครั้งเดียวตอน start — เปลี่ยนไม่ได้
#    read_env_file()    → อ่านจากดิสก์ทุกครั้ง — เห็นการเปลี่ยนแปลงทันที
#
#  Python ใช้ open() + readlines() เพราะ:
#    - ไม่ต้องการ library ภายนอก (stdlib only)
#    - ไฟล์ .env เล็กมาก latency ต่างกันแค่ microsecond
# ============================================================

def read_env_file(filename: str = ".env") -> dict[str, str]:
    """
    อ่านไฟล์ .env แล้วคืน dict {KEY: value}
    รองรับ format:
      KEY=value
      KEY="value with spaces"
      # comment (ข้าม)
      บรรทัดว่าง (ข้าม)
    ถ้าไฟล์ไม่มีหรือเปิดไม่ได้ คืน dict ว่าง ไม่ crash
    """
    result: dict[str, str] = {}
    try:
        with open(filename, encoding="utf-8") as f:
            for line in f:
                line = line.strip()

                # ข้ามบรรทัดว่างและ comment
                if not line or line.startswith("#"):
                    continue

                # แยก KEY=value (ตัดแค่ = ตัวแรก เผื่อ value มี = อยู่)
                if "=" not in line:
                    continue

                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip()

                # ลบ quote รอบ value ถ้ามี เช่น KEY="value" หรือ KEY='value'
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                    val = val[1:-1]

                result[key] = val

    except OSError:
        # ไฟล์ไม่มีหรือ permission denied — คืน dict ว่าง ไม่ crash
        print(f"[{_now_str()}] [WARN] cannot read {filename} — returning empty config")

    return result


def load_config() -> dict[str, str]:
    """
    อ่าน .env ใหม่ทุกครั้ง แล้วสร้าง config dict
    fallback chain: ค่าใน .env → os.environ → string ว่าง

    เรียกใน _handle_index() ทุก request
    เมื่อแก้ DATABASE_URI ใน .env → GET / ครั้งถัดไปเห็นค่าใหม่ทันที
    """
    env = read_env_file(".env")

    def get_val(key: str) -> str:
        # 1. ลองหาจากไฟล์ .env ก่อน (hot-reload)
        if env.get(key):
            return env[key]
        # 2. fallback ไปที่ process environment variable
        return os.environ.get(key, "")

    return {
        "database_url":   get_val("DATABASE_URI"),
        "redis_endpoint": get_val("REDIS_ENDPOINT"),
    }


# ============================================================
#  In-memory Store
# ============================================================

class EventStore:
    def __init__(self):
        self._events: list[dict] = []
        self._counter: int = 0
        self._lock = threading.Lock()

    def add(self, name: str, payload: dict) -> dict:
        with self._lock:
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
            return list(self._events)

    def find_by_id(self, event_id: str) -> dict | None:
        with self._lock:
            return next((e for e in self._events if e["id"] == event_id), None)

    def delete_by_id(self, event_id: str) -> dict | None:
        with self._lock:
            for i, e in enumerate(self._events):
                if e["id"] == event_id:
                    return self._events.pop(i)
            return None


store = EventStore()


# ============================================================
#  Helpers
# ============================================================

def _now_str() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def now_ts() -> int:
    return int(time.time())


def make_response(success: bool, message: str, data=None) -> dict:
    resp = {"success": success, "message": message, "timestamp": now_ts()}
    if data is not None:
        resp["data"] = data
    return resp


# ============================================================
#  Request Handler
# ============================================================

ROUTE_EVENTS   = re.compile(r"^/events$")
ROUTE_EVENT_ID = re.compile(r"^/events/(?P<id>[^/]+)$")


class EventHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        print(f"[{_now_str()}] [INFO] {fmt % args}")

    def send_json(self, status: int, data: dict):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json_body(self) -> dict | None:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return None

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
        # [แก้ไข] เพิ่ม field "config" ใน response
        # load_config() อ่านไฟล์ .env ใหม่ทุก request
        # เมื่อแก้ .env บน host → เห็นค่าใหม่ทันทีใน request ถัดไป
        cfg = load_config()     # ← อ่านสดทุกครั้ง

        self.send_json(200, make_response(True,
            "Python Event-Driven Web App is running!",
            {
                "status":  "healthy",
                "version": "1.0.0",
                "lang":    "python",
                "config":  cfg,     # ← เพิ่มใหม่
            }
        ))

    def _handle_list_events(self):
        events = store.list_all()
        self.send_json(200, make_response(True, f"found {len(events)} event(s)", events))

    def _handle_create_event(self):
        body = self.read_json_body()
        if body is None:
            self.send_json(400, make_response(False, "invalid JSON body"))
            return

        name = (body.get("name") or "").strip()
        if not name:
            print(f"[{_now_str()}] [WARN] rejected — name is empty")
            self.send_json(400, make_response(False, "name cannot be empty"))
            return

        payload = body.get("payload") or {}
        event = store.add(name, payload)
        print(f"[{_now_str()}] [INFO] created event id={event['id']} name={name}")
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
        print(f"[{_now_str()}] [INFO] deleted event id={event_id}")
        self.send_json(200, make_response(True, "event deleted", {"deleted_id": event_id}))


# ============================================================
#  Main
# ============================================================

if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))

    class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
        pass

    server = ThreadedHTTPServer((host, port), EventHandler)

    print(f"[{_now_str()}] [INFO] ================================")
    print(f"[{_now_str()}] [INFO]  Python Event-Driven Web App")
    print(f"[{_now_str()}] [INFO]  Listening on http://{host}:{port}")
    print(f"[{_now_str()}] [INFO] ================================")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n[{_now_str()}] [INFO] Shutting down...")
        server.shutdown()