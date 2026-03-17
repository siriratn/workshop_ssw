// ============================================================
//  โปรแกรม : Event-Driven Web Application
//  ภาษา    : Dart
//  Library  : Standard Library เท่านั้น
//               dart:io       — HttpServer (TCP/HTTP layer)
//               dart:convert  — json.encode / json.decode
//               dart:async    — Future, Stream (async/await)
// ============================================================

import 'dart:async';    // Future, Completer
import 'dart:convert';  // jsonEncode, jsonDecode
import 'dart:io';       // HttpServer, HttpRequest, Platform

// ============================================================
//  Data Structures
// ============================================================

// ใช้ Map<String, dynamic> แทน class เพื่อให้ jsonEncode ได้ตรงเลย
typedef EventMap = Map<String, dynamic>;

// สร้าง APIResponse เป็น Map
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
//  Dart รัน single-threaded event loop (ไม่มี race condition
//  แบบ multi-thread) แต่ใช้ async/await ทำให้ event-driven
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
    ..close(); // ปิด response (Future — non-blocking)
}

// ============================================================
//  Router
//  Dart ไม่มี built-in router ต้องเปรียบเทียบ path เอง
// ============================================================

final _eventIdPattern = RegExp(r'^/events/([^/]+)$');

Future<void> handleRequest(HttpRequest req, EventStore store) async {
  final method = req.method;
  final path = req.uri.path;
  final res = req.response;

  // log ทุก request
  print('[${DateTime.now()}] [INFO] $method $path');

  // อ่าน body แบบ async ผ่าน Stream
  // dart:io ใช้ Stream<Uint8List> สำหรับ request body
  Future<Map<String, dynamic>?> readBody() async {
    try {
      final bytes = await req.fold<List<int>>(
        [],
        (acc, chunk) => acc..addAll(chunk), // รวม chunks ทั้งหมด
      );
      if (bytes.isEmpty) return {};
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ── GET / ──────────────────────────────────────────────────
  if (method == 'GET' && path == '/') {
    sendJson(res, 200, apiOk('Dart Event-Driven Web App is running!', {
      'status': 'healthy',
      'version': '1.0.0',
      'lang': 'dart',
    }));
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
      print('[${DateTime.now()}] [WARN] rejected — name is empty');
      sendJson(res, 400, apiErr('name cannot be empty'));
      return;
    }
    final event = store.add(name, body['payload']);
    print('[${DateTime.now()}] [INFO] created event id=${event['id']} name=$name');
    sendJson(res, 201, apiOk('event created successfully', event));
    return;
  }

  // ── GET /events/{id}  และ  DELETE /events/{id} ─────────────
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

  // ── 404 ────────────────────────────────────────────────────
  sendJson(res, 404, apiErr('route not found: $path'));
}

// ============================================================
//  Main — App Runtime (Dart async event loop)
//  dart:io HttpServer ทำงานบน Dart event loop (single-thread)
//  ทุก request เป็น async event ที่ถูก dispatch ผ่าน Stream
// ============================================================

Future<void> main() async {
  final host = Platform.environment['HOST'] ?? '0.0.0.0';
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final store = EventStore();

  // bind ไปที่ address:port แล้ว listen แบบ async
  final server = await HttpServer.bind(host, port);

  print('===========================================');
  print('  Dart Event-Driven Web App  v1.0.0');
  print('  Listening on http://$host:$port');
  print('===========================================');

  // server เป็น Stream<HttpRequest>
  // await for = event loop — รอรับ event (request) ทีละตัว async
  await for (final request in server) {
    // รัน handler แบบ unawaited เพื่อไม่บล็อก event loop
    // ทำให้รับ request ถัดไปได้ทันที (concurrent)
    unawaited(handleRequest(request, store));
  }
}
