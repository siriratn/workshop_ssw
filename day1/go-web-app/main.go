package main

// ============================================================
//  โปรแกรม: Event-Driven Web Application
//  ภาษา  : Go
//  Library: Standard Library เท่านั้น (ไม่มี external package)
// ============================================================

import (
	"bufio"         // อ่านไฟล์ทีละบรรทัด — ใช้ใน readEnvFile()
	"context"       // จัดการ lifecycle ของ server (graceful shutdown)
	"encoding/json" // แปลง struct ↔ JSON
	"fmt"           // format string
	"log"           // logging
	"net/http"      // HTTP server และ router
	"os"            // อ่าน environment variable
	"os/signal"     // รับ OS signal (Ctrl+C)
	"strings"       // ตัด/ตรวจสอบ string
	"sync"          // Mutex สำหรับ thread-safe shared state
	"syscall"       // SIGTERM สำหรับ Docker stop
	"time"          // timestamp และ timeout
)

// ============================================================
//  [เพิ่มใหม่] Hot-reload config จาก .env
//  หลักการ: อ่านไฟล์ .env ใหม่ทุกครั้งที่ถูกเรียก
//  ไม่เก็บค่าใน memory / AppState เพราะจะทำให้ค่าค้างอยู่
//
//  ต่างจาก os.Getenv() ตรงที่:
//    os.Getenv()   → อ่านจาก process environment (set ครั้งเดียวตอน start)
//    readEnvFile() → อ่านจากไฟล์บนดิสก์ทุกครั้ง (เห็นการเปลี่ยนแปลงทันที)
// ============================================================

// readEnvFile อ่านไฟล์ .env แล้วคืน map[key]value
// รองรับ format:
//
//	KEY=value
//	# comment (ข้ามบรรทัดนี้)
//	บรรทัดว่าง (ข้าม)
func readEnvFile(filename string) map[string]string {
	result := make(map[string]string)

	f, err := os.Open(filename)
	if err != nil {
		// ไฟล์ไม่มีหรือเปิดไม่ได้ — คืน map ว่าง ไม่ panic
		log.Printf("[WARN] cannot open %s: %v", filename, err)
		return result
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// ข้ามบรรทัดว่างและ comment
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// แยก KEY=value (ตัดแค่ = ตัวแรก เผื่อ value มี = อยู่)
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])

		// ลบ quote รอบ value ถ้ามี เช่น KEY="value" หรือ KEY='value'
		if len(val) >= 2 {
			if (val[0] == '"' && val[len(val)-1] == '"') ||
				(val[0] == '\'' && val[len(val)-1] == '\'') {
				val = val[1 : len(val)-1]
			}
		}

		result[key] = val
	}

	return result
}

// ConfigSnapshot เก็บ config ที่ดึงมาจาก .env สำหรับ serialize ลง JSON
// สร้างใหม่ทุก request — ไม่มี cache ไม่มี mutex
type ConfigSnapshot struct {
	DatabaseURL   string `json:"database_url"`
	RedisEndpoint string `json:"redis_endpoint"`
}

// loadConfig อ่าน .env ใหม่ทุกครั้ง แล้วสร้าง ConfigSnapshot
// fallback chain: ค่าใน .env → ค่าใน process env → string ว่าง
func loadConfig() ConfigSnapshot {
	env := readEnvFile(".env")

	getVal := func(key string) string {
		// 1. ลองหาจากไฟล์ .env ก่อน (hot-reload)
		if v, ok := env[key]; ok && v != "" {
			return v
		}
		// 2. fallback ไปที่ process environment variable
		return os.Getenv(key)
	}

	return ConfigSnapshot{
		DatabaseURL:   getVal("DATABASE_URI"),
		RedisEndpoint: getVal("REDIS_ENDPOINT"),
	}
}

// ============================================================
//  Data Structures — โครงสร้าง JSON
// ============================================================

type Event struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt int64           `json:"created_at"`
}

type CreateEventRequest struct {
	Name    string          `json:"name"`
	Payload json.RawMessage `json:"payload"`
}

type APIResponse struct {
	Success   bool        `json:"success"`
	Message   string      `json:"message"`
	Data      interface{} `json:"data,omitempty"`
	Timestamp int64       `json:"timestamp"`
}

// ============================================================
//  In-memory Store
// ============================================================

type store struct {
	mu     sync.RWMutex
	events []Event
	nextID int
}

func newStore() *store { return &store{nextID: 1} }

func (s *store) add(e Event) Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	e.ID = fmt.Sprintf("evt-%04d", s.nextID)
	e.CreatedAt = time.Now().Unix()
	s.nextID++
	s.events = append(s.events, e)
	return e
}

func (s *store) list() []Event {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]Event, len(s.events))
	copy(result, s.events)
	return result
}

func (s *store) findByID(id string) (Event, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, e := range s.events {
		if e.ID == id {
			return e, true
		}
	}
	return Event{}, false
}

func (s *store) deleteByID(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, e := range s.events {
		if e.ID == id {
			s.events = append(s.events[:i], s.events[i+1:]...)
			return true
		}
	}
	return false
}

// ============================================================
//  Helpers
// ============================================================

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func respond(w http.ResponseWriter, status int, success bool, msg string, data interface{}) {
	writeJSON(w, status, APIResponse{
		Success:   success,
		Message:   msg,
		Data:      data,
		Timestamp: time.Now().Unix(),
	})
}

// ============================================================
//  Handlers
// ============================================================

// [แก้ไข] handleIndex GET /
// เพิ่ม field "config" ใน response โดยเรียก loadConfig() ทุก request
// เมื่อแก้ .env บน host แล้ว curl GET / → เห็นค่าใหม่ทันที
//
// ก่อนแก้: data มีแค่ status, version
// หลังแก้:  data มี status, version, config{ database_url, redis_endpoint }
func handleIndex(w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] %s %s", r.Method, r.URL.Path)

	// loadConfig() อ่านไฟล์ .env ใหม่ทุกครั้งที่มี request
	// ไม่มีการ cache — ถ้าแก้ .env ค่าจะเปลี่ยนใน request ถัดไปทันที
	cfg := loadConfig()

	respond(w, http.StatusOK, true, "Go Event-Driven Web App is running!", map[string]interface{}{
		"status":  "healthy",
		"version": "1.0.0",
		"config":  cfg, // ← เพิ่มใหม่
	})
}

func handleEvents(s *store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			listEvents(s, w, r)
		case http.MethodPost:
			createEvent(s, w, r)
		default:
			respond(w, http.StatusMethodNotAllowed, false, "method not allowed", nil)
		}
	}
}

func handleEventByID(s *store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/events/")
		if id == "" {
			respond(w, http.StatusBadRequest, false, "missing event id", nil)
			return
		}
		switch r.Method {
		case http.MethodGet:
			getEvent(s, w, r, id)
		case http.MethodDelete:
			deleteEvent(s, w, r, id)
		default:
			respond(w, http.StatusMethodNotAllowed, false, "method not allowed", nil)
		}
	}
}

func listEvents(s *store, w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] GET /events")
	events := s.list()
	respond(w, http.StatusOK, true, fmt.Sprintf("found %d event(s)", len(events)), events)
}

func createEvent(s *store, w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] POST /events")
	var req CreateEventRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, http.StatusBadRequest, false, "invalid JSON body", nil)
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		respond(w, http.StatusBadRequest, false, "name cannot be empty", nil)
		return
	}
	if req.Payload == nil {
		req.Payload = json.RawMessage(`{}`)
	}
	event := s.add(Event{Name: req.Name, Payload: req.Payload})
	log.Printf("[INFO] created event id=%s name=%s", event.ID, event.Name)
	respond(w, http.StatusCreated, true, "event created successfully", event)
}

func getEvent(s *store, w http.ResponseWriter, r *http.Request, id string) {
	log.Printf("[INFO] GET /events/%s", id)
	event, found := s.findByID(id)
	if !found {
		respond(w, http.StatusNotFound, false, fmt.Sprintf("event '%s' not found", id), nil)
		return
	}
	respond(w, http.StatusOK, true, "event found", event)
}

func deleteEvent(s *store, w http.ResponseWriter, r *http.Request, id string) {
	log.Printf("[INFO] DELETE /events/%s", id)
	if !s.deleteByID(id) {
		respond(w, http.StatusNotFound, false, fmt.Sprintf("event '%s' not found", id), nil)
		return
	}
	respond(w, http.StatusOK, true, "event deleted", map[string]string{"deleted_id": id})
}

// ============================================================
//  Main — App Runtime + Graceful Shutdown
// ============================================================

func main() {
	host := getEnv("HOST", "0.0.0.0")
	port := getEnv("PORT", "8080")
	addr := host + ":" + port

	s := newStore()

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			respond(w, http.StatusNotFound, false, "route not found", nil)
			return
		}
		handleIndex(w, r)
	})
	mux.HandleFunc("/events", handleEvents(s))
	mux.HandleFunc("/events/", handleEventByID(s))

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("[INFO] Server started on http://%s", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[ERROR] ListenAndServe: %v", err)
		}
	}()

	<-quit
	log.Println("[INFO] Shutting down server...")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("[ERROR] Server forced to shutdown: %v", err)
	}
	log.Println("[INFO] Server exited cleanly")
}

func getEnv(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}
