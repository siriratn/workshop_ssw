use actix_web::{web, App, HttpServer, HttpResponse, Responder};
use actix_web::middleware::Logger;
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

// ─── 1. เพิ่ม dotenvy เพื่ออ่าน .env ───────────────────────────────────────
// dotenvy::from_filename_iter() อ่านไฟล์แล้วคืน Iterator ของ (key, value)
// โดยไม่ set environment variable ลงใน process — เหมาะสำหรับ hot-reload
// เพราะถ้าใช้ dotenvy::dotenv() มันจะ set เข้า process env ซึ่ง immutable
use dotenvy::from_filename_iter;
use std::collections::HashMap;

// ─── Shared structs ─────────────────────────────────────────────────────────

#[derive(Serialize)]
struct ApiResponse<T: Serialize> {
    success: bool,
    message: String,
    data: Option<T>,
    timestamp: u64,
}

impl<T: Serialize> ApiResponse<T> {
    fn ok(message: &str, data: T) -> Self {
        Self {
            success: true,
            message: message.to_string(),
            data: Some(data),
            timestamp: now_secs(),
        }
    }
}

fn err_response(message: &str) -> ApiResponse<serde_json::Value> {
    ApiResponse {
        success: false,
        message: message.to_string(),
        data: None,
        timestamp: now_secs(),
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// ─── 2. ฟังก์ชัน read_env_file() ────────────────────────────────────────────
// อ่าน .env ทุกครั้งที่เรียก — ไม่ cache ไม่เก็บ state
// คืน HashMap<String, String> ของทุก key ในไฟล์
// ถ้าไฟล์ไม่มีหรืออ่านไม่ได้ คืน empty map (ไม่ panic)
fn read_env_file() -> HashMap<String, String> {
    match from_filename_iter(".env") {
        Ok(iter) => iter
            .filter_map(|item| item.ok())   // ข้าม line ที่ parse ไม่ได้
            .collect(),
        Err(_) => {
            warn!("Could not read .env file — returning empty config");
            HashMap::new()
        }
    }
}

// ─── 3. ConfigSnapshot — struct สำหรับ serialize เฉพาะ field ที่ต้องการ ─────
// สร้างใหม่ทุก request จาก read_env_file()
// ไม่มี lifetime, ไม่มี Arc, ไม่มี Mutex — อ่านแล้วทิ้ง
#[derive(Serialize)]
struct ConfigSnapshot {
    database_url:   String,
    redis_endpoint: String,
}

impl ConfigSnapshot {
    fn from_env_file() -> Self {
        let map = read_env_file();
        Self {
            // ถ้า key ไม่มีใน .env ให้ใช้ fallback จาก process env
            // แล้วค่อย fallback เป็น string ว่าง
            database_url: map
                .get("DATABASE_URI")
                .cloned()
                .or_else(|| std::env::var("DATABASE_URI").ok())
                .unwrap_or_default(),
            redis_endpoint: map
                .get("REDIS_ENDPOINT")
                .cloned()
                .or_else(|| std::env::var("REDIS_ENDPOINT").ok())
                .unwrap_or_default(),
        }
    }
}

// ─── 4. Response body สำหรับ GET / ──────────────────────────────────────────
#[derive(Serialize)]
struct IndexData {
    status: &'static str,
    config: ConfigSnapshot,   // <── field ใหม่ที่โจทย์ต้องการ
}

// ─── Handlers ───────────────────────────────────────────────────────────────

// ─── 5. index() อ่าน config ใหม่ทุก request ─────────────────────────────────
// ไม่มีการแตะ AppState เพื่อดึง config เลย
// ทุกครั้งที่ client GET / → read_env_file() ถูกเรียก → อ่านจากดิสก์ใหม่
// หาก ops แก้ DATABASE_URI ใน .env แล้ว call ใหม่ → เห็นค่าใหม่ทันที
async fn index() -> impl Responder {
    info!("GET /");

    let data = IndexData {
        status: "healthy",
        config: ConfigSnapshot::from_env_file(),  // อ่านสดทุกครั้ง
    };

    HttpResponse::Ok().json(ApiResponse::ok(
        "Rust Event-Driven Web App is running!",
        data,
    ))
}

// ─── Event structs & handlers (ไม่เปลี่ยน) ──────────────────────────────────

#[derive(Debug, Serialize, Deserialize, Clone)]
struct Event {
    id: String,
    name: String,
    payload: serde_json::Value,
    created_at: u64,
}

#[derive(Debug, Deserialize)]
struct CreateEventRequest {
    name: String,
    payload: Option<serde_json::Value>,
}

struct AppState {
    events: Mutex<Vec<Event>>,
}

async fn list_events(state: web::Data<AppState>) -> impl Responder {
    info!("GET /events");
    let events = state.events.lock().unwrap();
    HttpResponse::Ok().json(ApiResponse::ok(
        &format!("Found {} event(s)", events.len()),
        events.clone(),
    ))
}

async fn create_event(
    state: web::Data<AppState>,
    req: web::Json<CreateEventRequest>,
) -> impl Responder {
    info!("POST /events name={}", req.name);
    if req.name.trim().is_empty() {
        warn!("Rejected — name empty");
        return HttpResponse::BadRequest().json(err_response("name cannot be empty"));
    }
    let event = Event {
        id: format!("evt-{}", now_secs()),
        name: req.name.clone(),
        payload: req.payload.clone().unwrap_or(serde_json::json!({})),
        created_at: now_secs(),
    };
    state.events.lock().unwrap().push(event.clone());
    HttpResponse::Created().json(ApiResponse::ok("Event created", event))
}

async fn get_event(state: web::Data<AppState>, path: web::Path<String>) -> impl Responder {
    let id = path.into_inner();
    let events = state.events.lock().unwrap();
    match events.iter().find(|e| e.id == id) {
        Some(e) => HttpResponse::Ok().json(ApiResponse::ok("Found", e.clone())),
        None    => HttpResponse::NotFound().json(err_response("not found")),
    }
}

async fn delete_event(state: web::Data<AppState>, path: web::Path<String>) -> impl Responder {
    let id = path.into_inner();
    let mut events = state.events.lock().unwrap();
    let before = events.len();
    events.retain(|e| e.id != id);
    if events.len() < before {
        HttpResponse::Ok().json(ApiResponse::ok("Deleted", serde_json::json!({ "id": id })))
    } else {
        HttpResponse::NotFound().json(err_response("not found"))
    }
}

// ─── main ────────────────────────────────────────────────────────────────────

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    // ─── 6. ตอน startup โหลด .env เข้า process env ────────────────────────
    // dotenvy::dotenv() ใช้แค่ตอน start เพื่อ populate HOST, PORT, RUST_LOG
    // ซึ่งเป็น infra config ที่ไม่ต้อง hot-reload
    // DATABASE_URI / REDIS_ENDPOINT จะไม่ถูกใช้ผ่าน std::env ใน index()
    // แต่จะอ่านตรงจากไฟล์เสมอ
    let _ = dotenvy::dotenv();

    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    let addr = format!(
        "{}:{}",
        std::env::var("HOST").unwrap_or("0.0.0.0".into()),
        std::env::var("PORT").unwrap_or("8080".into())
    );
    info!("Listening on http://{}", addr);

    let state = web::Data::new(AppState { events: Mutex::new(Vec::new()) });

    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .wrap(Logger::default())
            .route("/",            web::get().to(index))
            .route("/events",      web::get().to(list_events))
            .route("/events",      web::post().to(create_event))
            .route("/events/{id}", web::get().to(get_event))
            .route("/events/{id}", web::delete().to(delete_event))
    })
    .bind(&addr)?
    .run()
    .await
}
