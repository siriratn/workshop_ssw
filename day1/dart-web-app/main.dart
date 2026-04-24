// ============================================================
//  โปรแกรม : Event-Driven Web Application
//  ภาษา    : Dart
//  Library  : Standard Library เท่านั้น
//               dart:io       — HttpServer, File, Platform
//               dart:convert  — json.encode / json.decode
//               dart:async    — Future, Stream
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ============================================================
//  EnvConfig — Hot-reload .env
//  อ่านไฟล์ .env ใหม่ทุก request โดยใช้ lastModified เป็น cache key
//  ถ้า .env ไม่เปลี่ยน → ใช้ cache (ลด IO)
//  ถ้า .env เปลี่ยน    → อ่านใหม่ทันที (hot-reload)
// ============================================================

class EnvConfig {
  // cache เก็บ key-value ที่อ่านได้ล่าสุด
  static Map<String, String> _cache = {};

  // เวลาที่ไฟล์ถูกแก้ไขล่าสุดที่เคยอ่าน
  static DateTime? _lastModified;

  // path ของ .env — อ่านจาก ENV_FILE หรือใช้ .env ใน working dir
  static final String _envPath =
      Platform.environment['ENV_FILE'] ?? '/app/.env';

  /// load() — เรียกทุก request
  /// ถ้า .env ไม่เปลี่ยน → return cache ทันที (O(1))
  /// ถ้า .env เปลี่ยน    → อ่านใหม่แล้ว update cache
  static Future<Map<String, String>> load() async {
    final file = File(_envPath);

    // ถ้าไม่มีไฟล์ .env → return cache เดิม (หรือ empty)
    if (!await file.exists()) {
      return _cache;
    }

    // ตรวจ lastModified — ถ้าไม่เปลี่ยนใช้ cache
    final modified = await file.lastModified();
    if (_lastModified != null && !modified.isAfter(_lastModified!)) {
      return _cache; // cache hit — ไม่ต้อง read file
    }

    // cache miss — อ่านไฟล์ใหม่
    final lines = await file.readAsLines();
    final newConfig = <String, String>{};

    for (final line in lines) {
      final trimmed = line.trim();
      // ข้าม comment และบรรทัดว่าง
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final eqIdx = trimmed.indexOf('=');
      if (eqIdx < 1) continue;

      final key = trimmed.substring(0, eqIdx).trim();
      final val = trimmed.substring(eqIdx + 1).trim();
      newConfig[key] = val;
    }

    // update cache + timestamp
    _cache = newConfig;
    _lastModified = modified;

    print(
      '[${DateTime.now()}] [CONFIG] .env reloaded (${newConfig.length} keys)',
    );
    return _cache;
  }

  /// get() — ดึงค่า key เดียว (สะดวกใช้ใน handler)
  static Future<String?> get(String key) async {
    final cfg = await load();
    return cfg[key];
  }
}

// ============================================================
//  Data Structures
// ============================================================

typedef EventMap = Map<String, dynamic>;

Map<String, dynamic> apiOk(String message, dynamic data) => {
      'success': true,
      'message': message,
      'data': data,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

Map<String, dynamic> apiErr(String message) => {
      'success': false,
      'message': message,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };

// ============================================================
//  In-memory Store
// ============================================================

class EventStore {
  final List<EventMap> _events = [];
  int _counter = 0;

  EventMap add(String name, dynamic payload) {
    _counter++;
    final event = {
      'id': 'evt-${_counter.toString().padLeft(4, '0')}',
      'name': name,
      'payload': payload ?? {},
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    _events.add(event);
    return event;
  }

  List<EventMap> listAll() => List.unmodifiable(_events);

  EventMap? findById(String id) {
    try {
      return _events.firstWhere((e) => e['id'] == id);
    } catch (_) {
      return null;
    }
  }

  EventMap? deleteById(String id) {
    final idx = _events.indexWhere((e) => e['id'] == id);
    if (idx == -1) return null;
    return _events.removeAt(idx);
  }
}

// ============================================================
//  HTTP Response Helper
// ============================================================

void sendJson(HttpResponse res, int status, Map<String, dynamic> body) {
  res
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body))
    ..close();
}

// ============================================================
//  Router
// ============================================================

final _eventIdPattern = RegExp(r'^/events/([^/]+)$');

Future<void> handleRequest(HttpRequest req, EventStore store) async {
  final method = req.method;
  final path = req.uri.path;
  final res = req.response;

  print('[${DateTime.now()}] [INFO] $method $path');

  Future<Map<String, dynamic>?> readBody() async {
    try {
      final bytes = await req.fold<List<int>>(
        [],
        (acc, chunk) => acc..addAll(chunk),
      );
      if (bytes.isEmpty) return {};
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ── GET /  — health check + hot-reload config ──────────────
  // อ่าน .env ทุกครั้งที่มี GET / เพื่อแสดงค่าล่าสุด
  if (method == 'GET' && path == '/') {
    // load() จะอ่านไฟล์ใหม่ถ้า .env เปลี่ยน หรือคืน cache ถ้าไม่เปลี่ยน
    final cfg = await EnvConfig.load();

    // แสดงเฉพาะ endpoint (ไม่แสดง password ใน URI เต็ม)
    sendJson(
      res,
      200,
      apiOk('Dart Event-Driven Web App is running!', {
        'status': 'healthy',
        'version': '1.0.0',
        'lang': 'dart',
        // hot-reload config — แสดง endpoint จาก .env
        'config': {
          'database_endpoint': _extractEndpoint(cfg['DATABASE_URI']),
          'redis_endpoint': cfg['REDIS_ENDPOINT'] ?? 'not set',
        },
      }),
    );
    return;
  }

  // ── GET /events ────────────────────────────────────────────
  if (method == 'GET' && path == '/events') {
    final events = store.listAll();
    sendJson(res, 200, apiOk('found ${events.length} event(s)', events));
    return;
  }

  // ── POST /events ───────────────────────────────────────────
  if (method == 'POST' && path == '/events') {
    final body = await readBody();
    if (body == null) {
      sendJson(res, 400, apiErr('invalid JSON body'));
      return;
    }
    final name = (body['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      print('[${DateTime.now()}] [WARN] rejected - name is empty');
      sendJson(res, 400, apiErr('name cannot be empty'));
      return;
    }
    final event = store.add(name, body['payload']);
    print(
      '[${DateTime.now()}] [INFO] created event id=${event['id']} name=$name',
    );
    sendJson(res, 201, apiOk('event created successfully', event));
    return;
  }

  // ── GET /events/{id}  /  DELETE /events/{id} ───────────────
  final match = _eventIdPattern.firstMatch(path);
  if (match != null) {
    final id = match.group(1)!;

    if (method == 'GET') {
      final event = store.findById(id);
      if (event == null) {
        sendJson(res, 404, apiErr("event '$id' not found"));
      } else {
        sendJson(res, 200, apiOk('event found', event));
      }
      return;
    }

    if (method == 'DELETE') {
      final removed = store.deleteById(id);
      if (removed == null) {
        sendJson(res, 404, apiErr("event '$id' not found"));
      } else {
        print('[${DateTime.now()}] [INFO] deleted event id=$id');
        sendJson(res, 200, apiOk('event deleted', {'deleted_id': id}));
      }
      return;
    }
  }

  sendJson(res, 404, apiErr('route not found: $path'));
}

// ============================================================
//  _extractEndpoint — แสดงเฉพาะ host:port จาก URI
//  postgres://user:pass@10.0.0.8:5432/mydb → 10.0.0.8:5432
// ============================================================
String _extractEndpoint(String? uri) {
  if (uri == null || uri.isEmpty) return 'not set';
  try {
    final parsed = Uri.parse(uri);
    return '${parsed.host}:${parsed.port}';
  } catch (_) {
    return uri;
  }
}

// ============================================================
//  Main — App Runtime
// ============================================================

Future<void> main() async {
  // Infra config อ่านจาก Platform.environment (ตอน startup เท่านั้น)
  final host = Platform.environment['HOST'] ?? '0.0.0.0';
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final store = EventStore();

  // โหลด .env ครั้งแรกตอน startup
  final initialCfg = await EnvConfig.load();
  print('===========================================');
  print('  Dart Event-Driven Web App  v1.0.0');
  print('  Listening on http://$host:$port');
  print('  DB  : ${_extractEndpoint(initialCfg['DATABASE_URI'])}');
  print('  Redis: ${initialCfg['REDIS_ENDPOINT'] ?? 'not set'}');
  print('  .env hot-reload: enabled (cache by mtime)');
  print('===========================================');

  final server = await HttpServer.bind(host, port);

  await for (final request in server) {
    unawaited(handleRequest(request, store));
  }
}
