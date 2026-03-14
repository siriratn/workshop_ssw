// ============================================================
//  โปรแกรม : Event-Driven Web Application
//  ภาษา    : C#  (.NET 8 Minimal API)
//  Library  : Standard Library เท่านั้น
//               Microsoft.AspNetCore  — HTTP server + routing
//               System.Text.Json      — JSON encode/decode
//               Microsoft.Extensions.Logging — logging
// ============================================================

// ── Imports (built-in ทั้งหมด ไม่ต้องติดตั้ง NuGet) ──────────
using System.Collections.Concurrent; // thread-safe dictionary
using System.Text.Json;               // JSON serialization
using System.Text.Json.Serialization; // JsonPropertyName attribute
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

// ============================================================
//  Data Structures — โครงสร้าง JSON
// ============================================================

// record = immutable data class ใน C# — เหมาะกับ DTO
// JsonPropertyName กำหนดชื่อ field ใน JSON

record Event(
    [property: JsonPropertyName("id")]         string Id,
    [property: JsonPropertyName("name")]       string Name,
    [property: JsonPropertyName("payload")]    JsonElement Payload,
    [property: JsonPropertyName("created_at")] long CreatedAt
);

record CreateEventRequest(
    [property: JsonPropertyName("name")]    string? Name,
    [property: JsonPropertyName("payload")] JsonElement? Payload
);

// Generic response wrapper — ครอบทุก response ให้รูปแบบเดียวกัน
record ApiResponse<T>(
    [property: JsonPropertyName("success")]   bool Success,
    [property: JsonPropertyName("message")]   string Message,
    [property: JsonPropertyName("data")]      T? Data,
    [property: JsonPropertyName("timestamp")] long Timestamp
)
{
    // Static factory methods สร้าง response สำเร็จรูป
    public static ApiResponse<T> Ok(string message, T data) =>
        new(true, message, data, DateTimeOffset.UtcNow.ToUnixTimeSeconds());

    public static ApiResponse<object?> Err(string message) =>
        new ApiResponse<object?>(false, message, null,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());
}

// ============================================================
//  In-memory Store
//  ConcurrentDictionary = thread-safe ในตัว ไม่ต้องใช้ lock
//  เพราะ ASP.NET Core รัน request แบบ async concurrent
// ============================================================
var store = new ConcurrentDictionary<string, Event>();
var counter = 0; // Interlocked.Increment ทำให้ atomic

// ============================================================
//  App Builder — Minimal API (ไม่ต้องมี Controller class)
// ============================================================
var builder = WebApplication.CreateBuilder(args);

// กำหนด port จาก environment variable
var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
var host = Environment.GetEnvironmentVariable("HOST") ?? "0.0.0.0";
builder.WebHost.UseUrls($"http://{host}:{port}");

// เปิด Logging (built-in)
builder.Logging.ClearProviders();
builder.Logging.AddConsole();

var app = builder.Build();
var logger = app.Logger;

// ============================================================
//  Middleware — Log ทุก request (Event-Driven concept)
//  Middleware = function ที่ถูกเรียกทุกครั้งที่มี HTTP event
// ============================================================
app.Use(async (context, next) =>
{
    logger.LogInformation("[INFO] {Method} {Path}", context.Request.Method, context.Request.Path);
    await next(context); // ส่งต่อไป handler ถัดไป
});

// ============================================================
//  Handlers (Route = Event Listener)
//  แต่ละ route เป็น lambda function ที่ถูกเรียกเมื่อ HTTP event ตรง
// ============================================================

// GET /  — health check
app.MapGet("/", () =>
{
    logger.LogInformation("[INFO] Health check");
    return Results.Ok(ApiResponse<object>.Ok(
        "C# Event-Driven Web App is running!",
        new { status = "healthy", version = "1.0.0", lang = "csharp" }
    ));
});

// GET /events  — list all events
app.MapGet("/events", () =>
{
    var events = store.Values.OrderBy(e => e.CreatedAt).ToList();
    logger.LogInformation("[INFO] List events count={Count}", events.Count);
    return Results.Ok(ApiResponse<List<Event>>.Ok(
        $"found {events.Count} event(s)", events));
});

// POST /events  — create new event
app.MapPost("/events", async (HttpRequest request) =>
{
    // อ่าน JSON body แบบ async
    CreateEventRequest? req;
    try
    {
        req = await request.ReadFromJsonAsync<CreateEventRequest>();
    }
    catch
    {
        return Results.BadRequest(ApiResponse<object?>.Err("invalid JSON body"));
    }

    // Validate
    if (req is null || string.IsNullOrWhiteSpace(req.Name))
    {
        logger.LogWarning("[WARN] rejected — name is empty");
        return Results.BadRequest(ApiResponse<object?>.Err("name cannot be empty"));
    }

    // Atomic increment สำหรับ ID — thread-safe โดยไม่ต้องใช้ lock
    var id = $"evt-{Interlocked.Increment(ref counter):D4}";
    var payload = req.Payload ?? JsonSerializer.Deserialize<JsonElement>("{}");
    var evt = new Event(id, req.Name, payload, DateTimeOffset.UtcNow.ToUnixTimeSeconds());

    store[id] = evt;
    logger.LogInformation("[INFO] Created event id={Id} name={Name}", id, req.Name);

    return Results.Created($"/events/{id}", ApiResponse<Event>.Ok("event created successfully", evt));
});

// GET /events/{id}  — get one event
app.MapGet("/events/{id}", (string id) =>
{
    if (!store.TryGetValue(id, out var evt))
    {
        logger.LogWarning("[WARN] event not found id={Id}", id);
        return Results.NotFound(ApiResponse<object?>.Err($"event '{id}' not found"));
    }
    return Results.Ok(ApiResponse<Event>.Ok("event found", evt));
});

// DELETE /events/{id}  — delete event
app.MapDelete("/events/{id}", (string id) =>
{
    if (!store.TryRemove(id, out var removed))
        return Results.NotFound(ApiResponse<object?>.Err($"event '{id}' not found"));

    logger.LogInformation("[INFO] Deleted event id={Id}", id);
    return Results.Ok(ApiResponse<object>.Ok("event deleted",
        new { deleted_id = removed.Id }));
});

// ── เริ่ม App Runtime (Event Loop ของ ASP.NET Core) ──────────
logger.LogInformation("[INFO] Starting C# Web App on http://{Host}:{Port}", host, port);
app.Run();
