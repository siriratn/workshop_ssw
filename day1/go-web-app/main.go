package main

// ============================================================
//  โปรแกรม: Event-Driven Web Application
//  ภาษา  : Go
//  Library: Standard Library เท่านั้น (ไม่มี external package)
// ============================================================

import (
	"context"          // จัดการ lifecycle ของ server (graceful shutdown)
	"encoding/json"    // แปลง struct ↔ JSON
	"fmt"              // format string
	"log"              // logging
	"net/http"         // HTTP server และ router
	"os"               // อ่าน environment variable
	"os/signal"        // รับ OS signal (Ctrl+C)
	"strings"          // ตัด/ตรวจสอบ string
	"sync"             // Mutex สำหรับ thread-safe shared state
	"syscall"          // SIGTERM สำหรับ Docker stop
	"time"             // timestamp และ timeout
)

// ============================================================
//  Data Structures — โครงสร้าง JSON
// ============================================================

// Event คือ domain object หลักของระบบ
// tag `json:"..."` บอกว่าเวลา encode/decode ใช้ชื่ออะไร
type Event struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Payload   json.RawMessage `json:"payload"`    // รับ JSON ใดก็ได้ ไม่ต้อง parse
	CreatedAt int64           `json:"created_at"` // Unix timestamp
}

// CreateEventRequest คือ body ที่ client ส่งมาทาง POST /events
type CreateEventRequest struct {
	Name    string          `json:"name"`
	Payload json.RawMessage `json:"payload"` // optional
}

// APIResponse ครอบ response ทุกตัวให้มีรูปแบบเดียวกัน
type APIResponse struct {
	Success   bool        `json:"success"`
	Message   string      `json:"message"`
	Data      interface{} `json:"data,omitempty"` // omitempty = ไม่แสดงถ้า nil
	Timestamp int64       `json:"timestamp"`
}

// ============================================================
//  In-memory Store — เก็บ events ไว้ใน memory
// ============================================================

// store เก็บ events และใช้ sync.RWMutex ป้องกัน race condition
// เพราะ HTTP handler แต่ละตัวรันใน goroutine ของตัวเอง (concurrent)
type store struct {
	mu     sync.RWMutex // RWMutex: อ่านพร้อมกันได้, เขียนต้องรอคนเดียว
	events []Event
	nextID int
}

func newStore() *store {
	return &store{nextID: 1}
}

// add เพิ่ม event ใหม่ — Lock() สำหรับการเขียน
func (s *store) add(e Event) Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	e.ID = fmt.Sprintf("evt-%04d", s.nextID)
	e.CreatedAt = time.Now().Unix()
	s.nextID++
	s.events = append(s.events, e)
	return e
}

// list คืน slice copy — RLock() สำหรับการอ่าน (หลายคนอ่านพร้อมกันได้)
func (s *store) list() []Event {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]Event, len(s.events))
	copy(result, s.events)
	return result
}

// findByID หา event จาก ID
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

// deleteByID ลบ event จาก ID คืน true ถ้าลบสำเร็จ
func (s *store) deleteByID(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, e := range s.events {
		if e.ID == id {
			// ลบโดยเอา index i ออก แล้วต่อ slice ที่เหลือ
			s.events = append(s.events[:i], s.events[i+1:]...)
			return true
		}
	}
	return false
}

// ============================================================
//  Helpers
// ============================================================

// writeJSON encode ข้อมูลเป็น JSON แล้วส่ง response
func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data) // stream encode ตรง writer
}

// respond สร้าง APIResponse สำเร็จรูปแล้ว writeJSON
func respond(w http.ResponseWriter, status int, success bool, msg string, data interface{}) {
	writeJSON(w, status, APIResponse{
		Success:   success,
		Message:   msg,
		Data:      data,
		Timestamp: time.Now().Unix(),
	})
}

// ============================================================
//  Handlers — แต่ละฟังก์ชันคือ "Event Listener" ของ HTTP event
// ============================================================

// handleIndex GET /
// ตอบ health check — ใช้ทดสอบว่า server ยังทำงานอยู่
func handleIndex(w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] %s %s", r.Method, r.URL.Path)
	respond(w, http.StatusOK, true, "Go Event-Driven Web App is running!", map[string]string{
		"status":  "healthy",
		"version": "1.0.0",
	})
}

// handleEvents แยก method GET/POST ออกจากกัน
// net/http ไม่มี method-based routing ในตัว ต้อง switch เอง
func handleEvents(s *store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			listEvents(s, w, r)
		case http.MethodPost:
			createEvent(s, w, r)
		default:
			// Method ที่ไม่รองรับ
			respond(w, http.StatusMethodNotAllowed, false, "method not allowed", nil)
		}
	}
}

// handleEventByID แยก GET/DELETE สำหรับ /events/{id}
func handleEventByID(s *store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// ตัด path prefix ออกเพื่อดึง id
		// r.URL.Path = "/events/evt-0001" → id = "evt-0001"
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

// listEvents GET /events — ดู event ทั้งหมด
func listEvents(s *store, w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] GET /events")
	events := s.list()
	respond(w, http.StatusOK, true, fmt.Sprintf("found %d event(s)", len(events)), events)
}

// createEvent POST /events — สร้าง event ใหม่
func createEvent(s *store, w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] POST /events")

	// Decode JSON body จาก request
	var req CreateEventRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("[WARN] bad request body: %v", err)
		respond(w, http.StatusBadRequest, false, "invalid JSON body", nil)
		return
	}

	// Validate
	if strings.TrimSpace(req.Name) == "" {
		log.Printf("[WARN] rejected — name is empty")
		respond(w, http.StatusBadRequest, false, "name cannot be empty", nil)
		return
	}

	// ถ้าไม่ส่ง payload มา ใส่ {} เป็นค่าเริ่มต้น
	if req.Payload == nil {
		req.Payload = json.RawMessage(`{}`)
	}

	event := s.add(Event{
		Name:    req.Name,
		Payload: req.Payload,
	})

	log.Printf("[INFO] created event id=%s name=%s", event.ID, event.Name)
	respond(w, http.StatusCreated, true, "event created successfully", event)
}

// getEvent GET /events/{id} — ดู event ตาม ID
func getEvent(s *store, w http.ResponseWriter, r *http.Request, id string) {
	log.Printf("[INFO] GET /events/%s", id)
	event, found := s.findByID(id)
	if !found {
		log.Printf("[WARN] event not found id=%s", id)
		respond(w, http.StatusNotFound, false, fmt.Sprintf("event '%s' not found", id), nil)
		return
	}
	respond(w, http.StatusOK, true, "event found", event)
}

// deleteEvent DELETE /events/{id} — ลบ event
func deleteEvent(s *store, w http.ResponseWriter, r *http.Request, id string) {
	log.Printf("[INFO] DELETE /events/%s", id)
	if !s.deleteByID(id) {
		respond(w, http.StatusNotFound, false, fmt.Sprintf("event '%s' not found", id), nil)
		return
	}
	log.Printf("[INFO] deleted event id=%s", id)
	respond(w, http.StatusOK, true, "event deleted", map[string]string{"deleted_id": id})
}

// ============================================================
//  Main — App Runtime + Graceful Shutdown
// ============================================================

func main() {
	// อ่าน config จาก environment variable
	// ถ้าไม่มีให้ใช้ค่า default
	host := getEnv("HOST", "0.0.0.0")
	port := getEnv("PORT", "8080")
	addr := host + ":" + port

	// สร้าง in-memory store
	s := newStore()

	// ── Register routes ──────────────────────────────────────
	// ServeMux คือ HTTP router ของ Go standard library
	mux := http.NewServeMux()

	// "/" จะ match ทุก path ที่ไม่มี handler อื่น
	// ต้องเช็ค exact match เองถ้าต้องการ
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			// path ไม่ตรง → 404
			respond(w, http.StatusNotFound, false, "route not found", nil)
			return
		}
		handleIndex(w, r)
	})
	mux.HandleFunc("/events", handleEvents(s))
	mux.HandleFunc("/events/", handleEventByID(s))

	// ── สร้าง HTTP server พร้อม timeout ──────────────────────
	// ป้องกัน slow client attack
	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second, // เวลาอ่าน request สูงสุด
		WriteTimeout: 10 * time.Second, // เวลาเขียน response สูงสุด
		IdleTimeout:  60 * time.Second, // เวลา keep-alive connection สูงสุด
	}

	// ── Graceful Shutdown ─────────────────────────────────────
	// รัน server ใน goroutine แยก แล้วรอ signal หลัก
	// เมื่อ Docker ส่ง SIGTERM หรือกด Ctrl+C จะ shutdown อย่าง clean
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	// รัน server ใน goroutine
	go func() {
		log.Printf("[INFO] Server started on http://%s", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[ERROR] ListenAndServe: %v", err)
		}
	}()

	// block รอ signal
	<-quit
	log.Println("[INFO] Shutting down server...")

	// ให้เวลา 5 วินาทีให้ request ที่ค้างอยู่ทำงานให้เสร็จก่อน
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("[ERROR] Server forced to shutdown: %v", err)
	}
	log.Println("[INFO] Server exited cleanly")
}

// getEnv อ่าน env var ถ้าไม่มีคืน fallback
func getEnv(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}
