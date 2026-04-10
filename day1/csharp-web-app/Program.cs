// ============================================================
//  Program.cs — C# Minimal API  (.NET 8)
//  กฎ C#: top-level statements ต้องอยู่ก่อน type declarations
//  ดังนั้นโครงสร้างไฟล์คือ:
//    1. using
//    2. top-level code (var, app.MapGet, app.Run ...)
//    3. type / record / class declarations  ← ท้ายสุด
// ============================================================

using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;

// ============================================================
//  TOP-LEVEL STATEMENTS — ต้องอยู่ก่อน type declarations
// ============================================================

var store   = new ConcurrentDictionary<string, Event>();
var counter = 0;

var builder = WebApplication.CreateBuilder(args);

var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
var host = Environment.GetEnvironmentVariable("HOST") ?? "0.0.0.0";
builder.WebHost.UseUrls($"http://{host}:{port}");
builder.Logging.ClearProviders();
builder.Logging.AddConsole();

var app    = builder.Build();
var logger = app.Logger;

// Middleware — log ทุก request
app.Use(async (context, next) =>
{
    logger.LogInformation("[INFO] {Method} {Path}",
        context.Request.Method, context.Request.Path);
    await next(context);
});

// GET /  — health check + hot-reload config
app.MapGet("/", () =>
{
    var cfg = EnvConfig.Load();
    return Results.Ok(ApiResponse<object>.Ok(
        "C# Event-Driven Web App is running!",
        new
        {
            status  = "healthy",
            version = "1.0.0",
            lang    = "csharp",
            config  = new
            {
                database_endpoint = EnvConfig.ExtractEndpoint(
                    cfg.GetValueOrDefault("DATABASE_URI")),
                redis_endpoint    = cfg.GetValueOrDefault("REDIS_ENDPOINT") ?? "not set",
            }
        }
    ));
});

// GET /events
app.MapGet("/events", () =>
{
    var events = store.Values.OrderBy(e => e.CreatedAt).ToList();
    logger.LogInformation("[INFO] List events count={Count}", events.Count);
    return Results.Ok(ApiResponse<List<Event>>.Ok(
        $"found {events.Count} event(s)", events));
});

// POST /events
app.MapPost("/events", async (HttpRequest request) =>
{
    CreateEventRequest? req;
    try { req = await request.ReadFromJsonAsync<CreateEventRequest>(); }
    catch { return Results.BadRequest(ApiResponse<object?>.Err("invalid JSON body")); }

    if (req is null || string.IsNullOrWhiteSpace(req.Name))
    {
        logger.LogWarning("[WARN] rejected - name is empty");
        return Results.BadRequest(ApiResponse<object?>.Err("name cannot be empty"));
    }

    var id      = $"evt-{Interlocked.Increment(ref counter):D4}";
    var payload = req.Payload ?? JsonSerializer.Deserialize<JsonElement>("{}");
    var evt     = new Event(id, req.Name, payload,
                      DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    store[id] = evt;
    logger.LogInformation("[INFO] Created event id={Id} name={Name}", id, req.Name);
    return Results.Created($"/events/{id}",
        ApiResponse<Event>.Ok("event created successfully", evt));
});

// GET /events/{id}
app.MapGet("/events/{id}", (string id) =>
{
    if (!store.TryGetValue(id, out var evt))
    {
        logger.LogWarning("[WARN] event not found id={Id}", id);
        return Results.NotFound(ApiResponse<object?>.Err($"event '{id}' not found"));
    }
    return Results.Ok(ApiResponse<Event>.Ok("event found", evt));
});

// DELETE /events/{id}
app.MapDelete("/events/{id}", (string id) =>
{
    if (!store.TryRemove(id, out var removed))
        return Results.NotFound(ApiResponse<object?>.Err($"event '{id}' not found"));
    logger.LogInformation("[INFO] Deleted event id={Id}", id);
    return Results.Ok(ApiResponse<object>.Ok("event deleted",
        new { deleted_id = removed.Id }));
});

// Startup log
var initialCfg = EnvConfig.Load();
logger.LogInformation("[INFO] Starting on http://{H}:{P}", host, port);
logger.LogInformation("[INFO] DB    : {DB}",
    EnvConfig.ExtractEndpoint(initialCfg.GetValueOrDefault("DATABASE_URI")));
logger.LogInformation("[INFO] Redis : {R}",
    initialCfg.GetValueOrDefault("REDIS_ENDPOINT") ?? "not set");

app.Run();

// ============================================================
//  TYPE DECLARATIONS — ต้องอยู่หลัง top-level statements
//  (กฎ C#: CS8803)
// ============================================================

// ── EnvConfig — Hot-reload .env ──────────────────────────────
// อ่านไฟล์ .env ใหม่เมื่อ mtime เปลี่ยน (cache hit = ไม่อ่านซ้ำ)
static class EnvConfig
{
    private static readonly string EnvPath =
        Environment.GetEnvironmentVariable("ENV_FILE") ?? "/app/.env";

    private static Dictionary<string, string> _cache       = new();
    private static DateTime                   _lastModified = DateTime.MinValue;
    private static readonly object            _lock         = new();

    public static Dictionary<string, string> Load()
    {
        if (!File.Exists(EnvPath)) return _cache;

        var modified = File.GetLastWriteTimeUtc(EnvPath);
        if (modified <= _lastModified) return _cache; // cache hit

        lock (_lock)
        {
            if (modified <= _lastModified) return _cache; // double-check

            var cfg = new Dictionary<string, string>();
            foreach (var line in File.ReadAllLines(EnvPath))
            {
                var t = line.Trim();
                if (string.IsNullOrEmpty(t) || t.StartsWith('#')) continue;
                var eq = t.IndexOf('=');
                if (eq < 1) continue;
                cfg[t[..eq].Trim()] = t[(eq + 1)..].Trim();
            }
            _cache        = cfg;
            _lastModified = modified;
            Console.WriteLine($"[CONFIG] .env reloaded ({cfg.Count} keys)");
        }
        return _cache;
    }

    public static string ExtractEndpoint(string? uri)
    {
        if (string.IsNullOrEmpty(uri)) return "not set";
        try { var u = new Uri(uri); return $"{u.Host}:{u.Port}"; }
        catch { return uri; }
    }
}

// ── Data Structures ──────────────────────────────────────────

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

record ApiResponse<T>(
    [property: JsonPropertyName("success")]   bool Success,
    [property: JsonPropertyName("message")]   string Message,
    [property: JsonPropertyName("data")]      T? Data,
    [property: JsonPropertyName("timestamp")] long Timestamp
)
{
    public static ApiResponse<T> Ok(string message, T data) =>
        new(true, message, data, DateTimeOffset.UtcNow.ToUnixTimeSeconds());

    public static ApiResponse<object?> Err(string message) =>
        new ApiResponse<object?>(false, message, null,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());
}
