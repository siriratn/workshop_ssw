#!/bin/bash

# ============================================================
#  โปรแกรม : Event-Driven Web Application
#  ภาษา    : Bash
#  Library  : Standard tools เท่านั้น
#               nc      — รับ/ส่ง TCP (transport layer)
#               awk     — ตัด/parse text
#               grep    — หา pattern
#               sed     — แทนที่ string
#               date    — timestamp
#               dd      — อ่าน request body ตาม Content-Length
# ============================================================

# ── Config ───────────────────────────────────────────────────
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"

# ── In-memory Store (ใช้ไฟล์ชั่วคราวแทน RAM) ─────────────────
# Bash ไม่มี shared memory ระหว่าง process
# แต่ละ request รันใน subshell ใหม่ จึงใช้ไฟล์ใน /tmp แทน
EVENTS_FILE="/tmp/events.json"
COUNTER_FILE="/tmp/event_counter.txt"

# ── Logging ──────────────────────────────────────────────────
# log ส่งไปที่ stderr เพื่อไม่ปนกับ HTTP response (stdout)
log() {
    local level="$1"
    local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >&2
}

# ============================================================
#  JSON Helpers
#  Bash ไม่มี built-in JSON parser ต้องประกอบ string เอง
# ============================================================

# now_ts คืน Unix timestamp ปัจจุบัน
now_ts() { date +%s; }

# json_ok สร้าง APIResponse สำเร็จรูป
# $1=message  $2=data (JSON string หรือว่าง)
json_ok() {
    local msg="$1"
    local data="$2"
    if [ -n "$data" ]; then
        printf '{"success":true,"message":"%s","data":%s,"timestamp":%s}' \
            "$msg" "$data" "$(now_ts)"
    else
        printf '{"success":true,"message":"%s","timestamp":%s}' \
            "$msg" "$(now_ts)"
    fi
}

# json_err สร้าง error response
json_err() {
    local msg="$1"
    printf '{"success":false,"message":"%s","timestamp":%s}' \
        "$msg" "$(now_ts)"
}

# ============================================================
#  HTTP Response Helper
#  HTTP/1.1 response ต้องมี: status line, headers, blank line, body
#  \r\n (CRLF) คือ line ending มาตรฐานของ HTTP spec
# ============================================================
http_response() {
    local status="$1"   # เช่น "200 OK", "404 Not Found"
    local body="$2"
    local len=${#body}
    # printf ส่ง CRLF ออก stdout → nc → client
    printf "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
        "$status" "$len" "$body"
}

# ============================================================
#  In-memory Store Operations
# ============================================================

# store_init สร้างไฟล์ถ้ายังไม่มี
store_init() {
    [ -f "$EVENTS_FILE" ]  || echo "[]" > "$EVENTS_FILE"
    [ -f "$COUNTER_FILE" ] || echo "0"  > "$COUNTER_FILE"
}

# store_next_id เพิ่ม counter แล้วคืน ID ใหม่
# flock ป้องกัน race condition เมื่อหลาย request เข้าพร้อมกัน
store_next_id() {
    (
        flock -x 200                            # lock ก่อนอ่าน-เขียน
        local n
        n=$(cat "$COUNTER_FILE")
        n=$((n + 1))
        echo "$n" > "$COUNTER_FILE"
        printf "evt-%04d" "$n"                  # format: evt-0001
    ) 200>"$COUNTER_FILE.lock"
}

# store_add เพิ่ม event ใหม่เข้า JSON array ใน EVENTS_FILE
# ใช้ awk ต่อ JSON object เข้ากับ array ที่มีอยู่
store_add() {
    local id="$1"
    local name="$2"
    local payload="$3"
    local ts
    ts=$(now_ts)

    # สร้าง JSON object ของ event
    local obj
    obj=$(printf '{"id":"%s","name":"%s","payload":%s,"created_at":%s}' \
        "$id" "$name" "$payload" "$ts")

    (
        flock -x 200
        local current
        current=$(cat "$EVENTS_FILE")
        # ถ้า array ว่าง [] ใส่ตัวแรกเลย ถ้าไม่ว่างให้ต่อด้วย ,
        if [ "$current" = "[]" ]; then
            echo "[$obj]" > "$EVENTS_FILE"
        else
            # ตัด ] ท้ายออก แล้วต่อ ,obj]
            echo "${current%]},$obj]" > "$EVENTS_FILE"
        fi
        echo "$obj"    # คืน object ที่สร้าง
    ) 200>"$EVENTS_FILE.lock"
}

# store_list คืน JSON array ทั้งหมด
store_list() {
    (
        flock -s 200   # shared lock (อ่านพร้อมกันได้)
        cat "$EVENTS_FILE"
    ) 200>"$EVENTS_FILE.lock"
}

# store_find_by_id หา event จาก id ด้วย grep + awk
store_find_by_id() {
    local id="$1"
    (
        flock -s 200
        # แปลง array เป็นทีละบรรทัด แล้ว grep หา id
        # awk ใช้ RS (record separator) = "},{" แยกแต่ละ object
        awk -v id="\"id\":\"$id\"" 'BEGIN{RS="\\},\\{"} $0~id{
            gsub(/^\[/,""); gsub(/\]$/,"")
            gsub(/^\{/,""); gsub(/\}$/,"")
            print "{"$0"}"
        }' "$EVENTS_FILE"
    ) 200>"$EVENTS_FILE.lock"
}

# store_delete_by_id ลบ event ด้วย sed
store_delete_by_id() {
    local id="$1"
    (
        flock -x 200
        local current
        current=$(cat "$EVENTS_FILE")
        # ตรวจว่า id มีอยู่ก่อน
        if ! echo "$current" | grep -q "\"id\":\"$id\""; then
            echo "NOT_FOUND"
            return
        fi
        # ลบ object ที่มี id นี้ออกจาก JSON array
        # sed pattern: ลบ {...,"id":"evt-XXXX",...} รวม comma รอบข้าง
        local new
        new=$(echo "$current" | \
            sed "s/,{[^}]*\"id\":\"$id\"[^}]*}//g" | \
            sed "s/{[^}]*\"id\":\"$id\"[^}]*},//g"  | \
            sed "s/{[^}]*\"id\":\"$id\"[^}]*}//g")
        # ถ้าลบหมดแล้วให้เป็น []
        echo "$new" | grep -q '{' || new="[]"
        echo "$new" > "$EVENTS_FILE"
        echo "OK"
    ) 200>"$EVENTS_FILE.lock"
}

# ============================================================
#  Request Parser
#  อ่าน HTTP request จาก stdin (ที่ nc ส่งมา)
# ============================================================
parse_request() {
    # อ่าน Request Line บรรทัดแรก: "POST /events HTTP/1.1"
    read -r request_line
    # ตัด \r ออก (HTTP ใช้ CRLF)
    request_line="${request_line%$'\r'}"

    # แยก method และ path
    METHOD=$(echo "$request_line" | awk '{print $1}')
    REQ_PATH=$(echo "$request_line" | awk '{print $2}')

    # อ่าน Headers จนเจอบรรทัดว่าง
    CONTENT_LENGTH=0
    while IFS= read -r header; do
        header="${header%$'\r'}"
        [ -z "$header" ] && break   # blank line = จบ headers
        # ดึง Content-Length เพื่อรู้ว่า body ยาวแค่ไหน
        if echo "$header" | grep -qi "^content-length:"; then
            CONTENT_LENGTH=$(echo "$header" | awk -F': ' '{print $2}' | tr -d ' \r')
        fi
    done

    # อ่าน Body ตาม Content-Length (สำคัญมาก — ต้องอ่านให้ครบ)
    BODY=""
    if [ "${CONTENT_LENGTH:-0}" -gt 0 ]; then
        BODY=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    fi
}

# ============================================================
#  Router — จับคู่ METHOD + PATH → handler ที่ถูกต้อง
# ============================================================
route() {
    local method="$1"
    local path="$2"
    local body="$3"

    log "INFO" "$method $path"

    # GET /
    if [ "$method" = "GET" ] && [ "$path" = "/" ]; then
        handle_index
        return
    fi

    # GET /events  หรือ  POST /events
    if [ "$path" = "/events" ]; then
        case "$method" in
            GET)    handle_list_events ;;
            POST)   handle_create_event "$body" ;;
            *)      http_response "405 Method Not Allowed" "$(json_err "method not allowed")" ;;
        esac
        return
    fi

    # GET /events/{id}  หรือ  DELETE /events/{id}
    if echo "$path" | grep -qE "^/events/[^/]+$"; then
        # ตัด /events/ prefix ออกเพื่อดึง id
        local id="${path#/events/}"
        case "$method" in
            GET)    handle_get_event "$id" ;;
            DELETE) handle_delete_event "$id" ;;
            *)      http_response "405 Method Not Allowed" "$(json_err "method not allowed")" ;;
        esac
        return
    fi

    # ไม่มี route ตรง → 404
    http_response "404 Not Found" "$(json_err "route not found: $path")"
}

# ============================================================
#  Handlers
# ============================================================

# GET /
handle_index() {
    local data='{"status":"healthy","version":"1.0.0","lang":"bash"}'
    http_response "200 OK" "$(json_ok "Bash Event-Driven Web App is running!" "$data")"
}

# GET /events
handle_list_events() {
    local events
    events=$(store_list)
    # นับจำนวน event จาก "id": ใน JSON
    local count
    count=$(echo "$events" | grep -o '"id"' | wc -l | tr -d ' ')
    http_response "200 OK" "$(json_ok "found $count event(s)" "$events")"
}

# POST /events  — รับ JSON body สร้าง event ใหม่
handle_create_event() {
    local body="$1"

    # ดึง name จาก JSON body ด้วย grep + sed
    # pattern: หา "name":"ค่า" แล้วตัดเอาแค่ค่า
    local name
    name=$(echo "$body" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')

    # Validate
    if [ -z "$name" ]; then
        log "WARN" "rejected — name is empty"
        http_response "400 Bad Request" "$(json_err "name cannot be empty")"
        return
    fi

    # ดึง payload (ถ้าไม่มีให้เป็น {})
    local payload
    payload=$(echo "$body" | grep -o '"payload":{[^}]*}' | sed 's/"payload"://')
    [ -z "$payload" ] && payload="{}"

    # สร้าง event
    local id
    id=$(store_next_id)
    local event
    event=$(store_add "$id" "$name" "$payload")

    log "INFO" "created event id=$id name=$name"
    http_response "201 Created" "$(json_ok "event created successfully" "$event")"
}

# GET /events/{id}
handle_get_event() {
    local id="$1"
    local event
    event=$(store_find_by_id "$id")

    if [ -z "$event" ]; then
        log "WARN" "event not found id=$id"
        http_response "404 Not Found" "$(json_err "event '$id' not found")"
        return
    fi

    http_response "200 OK" "$(json_ok "event found" "$event")"
}

# DELETE /events/{id}
handle_delete_event() {
    local id="$1"
    local result
    result=$(store_delete_by_id "$id")

    if [ "$result" = "NOT_FOUND" ]; then
        http_response "404 Not Found" "$(json_err "event '$id' not found")"
        return
    fi

    log "INFO" "deleted event id=$id"
    http_response "200 OK" "$(json_ok "event deleted" "{\"deleted_id\":\"$id\"}")"
}

# ============================================================
#  Main — App Runtime (Event Loop)
#  nc -l  = listen mode รอรับ connection
#  while  = loop รับ connection ใหม่ทุกครั้ง (event loop)
# ============================================================
main() {
    store_init

    log "INFO" "============================================"
    log "INFO" "  Bash Event-Driven Web App  v1.0.0"
    log "INFO" "  Listening on http://$HOST:$PORT"
    log "INFO" "============================================"

    # Event Loop หลัก
    # ทุกครั้งที่มี client connect เข้ามา nc จะส่ง request มาทาง stdin
    # handler อ่าน stdin → ประมวลผล → เขียน response กลับ stdout → nc ส่งต่อไป client
    while true; do
        # nc -l -p PORT รอรับ 1 connection
        # process substitution <(...) ป้อน response กลับไปทาง nc
        {
            parse_request
            route "$METHOD" "$REQ_PATH" "$BODY"
        } | nc -l -p "$PORT" -q 1
        # -q 1 = รอ 1 วินาทีหลัง stdin ปิดก่อน nc ปิด connection
    done
}

# เรียก main เมื่อรัน script โดยตรง
main
