<?php

// ============================================================
//  โปรแกรม : Event-Driven Web Application
//  ภาษา    : PHP 8.2 (built-in web server)
//  Library  : Standard Library เท่านั้น
//               $_SERVER       — request method, URI
//               file_get_contents('php://input') — request body
//               json_encode / json_decode — JSON
//               header()       — HTTP response headers
//               http_response_code() — HTTP status code
// ============================================================

declare(strict_types=1);

// ============================================================
//  Helpers
// ============================================================

function nowTs(): int
{
    return time(); // Unix timestamp
}

function apiOk(string $message, mixed $data): array
{
    return [
        'success'   => true,
        'message'   => $message,
        'data'      => $data,
        'timestamp' => nowTs(),
    ];
}

function apiErr(string $message): array
{
    return [
        'success'   => false,
        'message'   => $message,
        'timestamp' => nowTs(),
    ];
}

// ส่ง JSON response พร้อม status code
function sendJson(int $status, array $body): never
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body, JSON_UNESCAPED_UNICODE);
    exit; // PHP script-based = จบ script = จบ response
}

// log ออก stderr (เพื่อให้ docker logs เห็น)
function logMsg(string $level, string $msg): void
{
    $ts = date('Y-m-d H:i:s');
    file_put_contents('php://stderr', "[$ts] [$level] $msg\n");
}

// ============================================================
//  In-memory Store
//  PHP built-in server รัน single process per request
//  ต้องใช้ไฟล์ /tmp แทน memory (เหมือน Bash)
//  เพราะแต่ละ request เป็น process ใหม่ ไม่แชร์ memory
// ============================================================

const EVENTS_FILE  = '/app/data/php_events.json';
const COUNTER_FILE = '/app/data/php_counter.txt';

function storeInit(): void
{
    if (!file_exists(EVENTS_FILE))  file_put_contents(EVENTS_FILE, '[]');
    if (!file_exists(COUNTER_FILE)) file_put_contents(COUNTER_FILE, '0');
}

// lock file ป้องกัน race condition เมื่อ concurrent requests
function withLock(callable $fn): mixed
{
    $lockFile = fopen(EVENTS_FILE . '.lock', 'c');
    flock($lockFile, LOCK_EX); // exclusive lock
    try {
        return $fn();
    } finally {
        flock($lockFile, LOCK_UN);
        fclose($lockFile);
    }
}

function storeAdd(string $name, mixed $payload): array
{
    return withLock(function () use ($name, $payload) {
        $counter = (int) file_get_contents(COUNTER_FILE) + 1;
        file_put_contents(COUNTER_FILE, (string) $counter);

        $event = [
            'id'         => sprintf('evt-%04d', $counter),
            'name'       => $name,
            'payload'    => $payload ?? new stdClass(), // {} ใน JSON
            'created_at' => nowTs(),
        ];

        $events   = json_decode(file_get_contents(EVENTS_FILE), true);
        $events[] = $event;
        file_put_contents(EVENTS_FILE, json_encode($events));

        return $event;
    });
}

function storeList(): array
{
    return withLock(fn () =>
        json_decode(file_get_contents(EVENTS_FILE), true) ?? []
    );
}

function storeFindById(string $id): ?array
{
    return withLock(function () use ($id) {
        $events = json_decode(file_get_contents(EVENTS_FILE), true) ?? [];
        foreach ($events as $event) {
            if ($event['id'] === $id) return $event;
        }
        return null;
    });
}

function storeDeleteById(string $id): ?array
{
    return withLock(function () use ($id) {
        $events = json_decode(file_get_contents(EVENTS_FILE), true) ?? [];
        foreach ($events as $i => $event) {
            if ($event['id'] === $id) {
                array_splice($events, $i, 1);
                file_put_contents(EVENTS_FILE, json_encode($events));
                return $event;
            }
        }
        return null;
    });
}

// ============================================================
//  Router
//  PHP built-in server เรียก script นี้ทุกครั้งที่มี request
//  $_SERVER['REQUEST_METHOD'] และ $_SERVER['REQUEST_URI']
//  บอก method และ path ของ request
// ============================================================

storeInit();

$method = $_SERVER['REQUEST_METHOD'];
$path   = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

logMsg('INFO', "$method $path");

// ── GET / ─────────────────────────────────────────────────
if ($method === 'GET' && $path === '/') {
    sendJson(200, apiOk('PHP Event-Driven Web App is running!', [
        'status'  => 'healthy',
        'version' => '1.0.0',
        'lang'    => 'php',
    ]));
}

// ── GET /events ───────────────────────────────────────────
if ($method === 'GET' && $path === '/events') {
    $events = storeList();
    sendJson(200, apiOk('found ' . count($events) . ' event(s)', $events));
}

// ── POST /events ──────────────────────────────────────────
if ($method === 'POST' && $path === '/events') {
    // php://input อ่าน raw request body
    $raw  = file_get_contents('php://input');
    $body = json_decode($raw, true);

    if ($body === null && $raw !== '') {
        sendJson(400, apiErr('invalid JSON body'));
    }

    $name = trim($body['name'] ?? '');
    if ($name === '') {
        logMsg('WARN', 'rejected — name is empty');
        sendJson(400, apiErr('name cannot be empty'));
    }

    $payload = $body['payload'] ?? null;
    $event   = storeAdd($name, $payload);
    logMsg('INFO', "created event id={$event['id']} name=$name");
    sendJson(201, apiOk('event created successfully', $event));
}

// ── /events/{id} ──────────────────────────────────────────
if (preg_match('#^/events/([^/]+)$#', $path, $matches)) {
    $id = $matches[1];

    if ($method === 'GET') {
        $event = storeFindById($id);
        if ($event === null) {
            sendJson(404, apiErr("event '$id' not found"));
        }
        sendJson(200, apiOk('event found', $event));
    }

    if ($method === 'DELETE') {
        $removed = storeDeleteById($id);
        if ($removed === null) {
            sendJson(404, apiErr("event '$id' not found"));
        }
        logMsg('INFO', "deleted event id=$id");
        sendJson(200, apiOk('event deleted', ['deleted_id' => $id]));
    }
}

// ── 404 ──────────────────────────────────────────────────
sendJson(404, apiErr("route not found: $path"));
