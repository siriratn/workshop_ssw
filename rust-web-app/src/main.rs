use actix_web::{web, App, HttpServer, HttpResponse, Responder};
use actix_web::middleware::Logger;
use log::{info, warn};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

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

async fn index() -> impl Responder {
    info!("GET /");
    HttpResponse::Ok().json(ApiResponse::ok(
        "Rust Event-Driven Web App is running!",
        serde_json::json!({ "status": "healthy" }),
    ))
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
        None => HttpResponse::NotFound().json(err_response("not found")),
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

#[actix_web::main]
async fn main() -> std::io::Result<()> {
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
