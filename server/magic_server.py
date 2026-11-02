import os
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Magic Control Server (Windows + macOS)
HTTP API:
  GET  /health
  POST /event   (critical: click/gesture/command)  - retries/seq safe
  POST /motion  (non-critical: cursor movement)    - best-effort / rate-limited

Dependencies:
  pip install fastapi uvicorn pynput

macOS IMPORTANT:
  To control mouse/keyboard you must allow Accessibility permissions:
  System Settings -> Privacy & Security -> Accessibility -> enable for your Python / Terminal.

Run:
  python magic_server.py
"""
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Magic Control Server (Windows + macOS) — single-file, production-ish skeleton.

✅ Cross-platform cursor/keyboard control via pynput (Windows/macOS)
✅ HTTPS-ready behind nginx (you already proxy to http://127.0.0.1:777)
✅ Fully logs *all* HTTP requests (method, path, IP, headers subset, body, response code, latency)
✅ Profiles: mouse / presentation / media (+ custom placeholder)
✅ Gesture maps per profile (ideal defaults, easy to tune)
✅ Reliability: seq dedupe, retry-safe critical events
✅ Motion: rate-limited, best-effort, coalescing friendly

Dependencies:
  pip install fastapi uvicorn pynput

macOS IMPORTANT:
  System Settings -> Privacy & Security -> Accessibility -> enable your Terminal/Python
  (Otherwise mouse/keyboard control will not work.)

Run:
  python magic_server.py
"""

# =========================
# CONFIG (ALL SETTINGS HERE)
# =========================

HOST = "0.0.0.0"
PORT = 777

# If empty -> auth disabled (NOT recommended for public internet).
AUTH_BEARER_TOKEN = os.environ['MAGIC_CONTROL_TOKEN']
if not AUTH_BEARER_TOKEN:
    raise RuntimeError('MAGIC_CONTROL_TOKEN must be nonempty')

# Logging
LOG_FILE = "magic_server.log"
LOG_LEVEL = "DEBUG"  # DEBUG/INFO/WARNING/ERROR
LOG_MAX_BYTES = 25 * 1024 * 1024
LOG_BACKUPS = 5

# Request logging details
LOG_HEADERS_WHITELIST = {
    "host", "user-agent", "content-type", "content-length", "authorization", "x-forwarded-for", "x-real-ip"
}
LOG_MAX_BODY_BYTES = 8192  # log at most N bytes of request body

# Motion handling
MOTION_ENABLED_DEFAULT = True
MOTION_MIN_INTERVAL_MS = 10           # per-device rate-limit (coalesce)
MOTION_MAX_SAMPLES_PER_REQUEST = 96   # sanity limit
MOTION_SCALE = 22.0                   # watch dx/dy -> pixels (tune)
MOTION_ACCELERATION = 0.0             # 0..1 adds accel based on speed; keep 0 initially
MOTION_DEADZONE = 0.0                 # ignore tiny sums; 0.0 means off (watch already filters)
MOTION_PROFILE_ONLY = {"mouse"}       # only profiles allowed to move cursor (others ignore motion)

# Critical events reliability
ALLOW_OUT_OF_ORDER_GAPS = True        # accept seq jumps (log them)
IGNORE_DUPLICATES = True              # seq <= last_seq -> ignore (idempotent)

# Key press pacing
KEY_COMBO_PRESS_DELAY_MS = 0          # 0 is fine; can set 10-30 if some apps miss combos

# Safety
ALLOW_PANIC_STOP = True               # shake/panicStop command disables motion instantly
PANIC_ALSO_RELEASE_DRAG = True

# =========================
# PROFILE MAPS ("IDEAL" DEFAULTS)
# =========================
# Notes:
# - "mouse" prioritizes scroll/nav/drag.
# - "presentation" prioritizes next/prev, laser (optional), full screen, pause.
# - "media" prioritizes play/pause, next/prev, volume, mute.
#
# Actions supported:
#   {"type":"click", "button":"left|right|doubleLeft"}
#   {"type":"drag",  "state":"start|end"}
#   {"type":"scroll","amount": int}          # vertical scroll steps
#   {"type":"key",   "combo":[...]}          # e.g. ["space"] or ["cmd","tab"]
#   {"type":"text",  "value":"a"}            # types text (rarely needed)
#   {"type":"panic"}                         # disables motion, releases drag (if enabled)

PROFILE_GESTURE_MAPS = {
    # ---- MOUSE ----
    "mouse": {
        "pinch":             {"type": "click", "button": "left"},
        "pinch_hold_start":  {"type": "drag",  "state": "start"},
        "pinch_hold_end":    {"type": "drag",  "state": "end"},

        # Fast direction flicks = navigation (browser / back-forward) and utility
        "flick_left":        {"type": "key",   "combo": ["alt", "left"]},   # back
        "flick_right":       {"type": "key",   "combo": ["alt", "right"]},  # forward
        "flick_up":          {"type": "scroll","amount": +6},
        "flick_down":        {"type": "scroll","amount": -6},

        # Rotate for fine scroll
        "rotate_cw":         {"type": "scroll","amount": +2},
        "rotate_ccw":        {"type": "scroll","amount": -2},

        # Shake = panic stop
        "shake":             {"type": "panic"},
    },

    # ---- PRESENTATION ----
    "presentation": {
        "pinch":             {"type": "key",   "combo": ["right"]},  # next slide
        "pinch_hold_start":  {"type": "key",   "combo": ["shift", "f5"]},  # start slideshow (PowerPoint)
        "pinch_hold_end":    {"type": "key",   "combo": ["esc"]},    # end slideshow

        "flick_left":        {"type": "key",   "combo": ["left"]},   # prev
        "flick_right":       {"type": "key",   "combo": ["right"]},  # next
        "flick_up":          {"type": "key",   "combo": ["f5"]},     # start (fallback)
        "flick_down":        {"type": "key",   "combo": ["esc"]},    # stop

        # Rotate = pointer/laser alternative: many apps use "b"/"w" (PowerPoint) or volume not relevant
        "rotate_cw":         {"type": "key",   "combo": ["b"]},      # black screen (PowerPoint)
        "rotate_ccw":        {"type": "key",   "combo": ["w"]},      # white screen (PowerPoint)

        "shake":             {"type": "panic"},
    },

    # ---- MEDIA ----
    "media": {
        "pinch":             {"type": "key",   "combo": ["space"]},  # play/pause (works in many players)
        "pinch_hold_start":  {"type": "key",   "combo": ["m"]},      # mute (works in many web players)
        "pinch_hold_end":    {"type": "key",   "combo": ["m"]},      # toggle mute back

        "flick_left":        {"type": "key",   "combo": ["j"]},      # back 10s (YouTube)
        "flick_right":       {"type": "key",   "combo": ["l"]},      # forward 10s
        "flick_up":          {"type": "key",   "combo": ["up"]},     # volume up (many apps)
        "flick_down":        {"type": "key",   "combo": ["down"]},   # volume down

        "rotate_cw":         {"type": "key",   "combo": [">"]},      # next track (often shift+. or player-specific)
        "rotate_ccw":        {"type": "key",   "combo": ["<"]},      # prev track

        "shake":             {"type": "panic"},
    },

    # ---- CUSTOM (placeholder, safe defaults) ----
    "custom": {
        "pinch":            {"type": "click", "button": "left"},
        "shake":            {"type": "panic"},
    }
}

# Optional: per-profile click mapping (when watch sends click kinds directly)
# Typically you keep click as-is, but you can override behavior here if needed.
PROFILE_CLICK_RULES = {
    "mouse": "native",
    "presentation": "native",
    "media": "native",
    "custom": "native",
}

# =========================
# IMPLEMENTATION
# =========================

import sys
import time
import json
import platform
import logging
from logging.handlers import RotatingFileHandler
from typing import Optional, List, Dict, Any, Tuple

from fastapi import FastAPI, Request, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from pynput.mouse import Controller as MouseController, Button
from pynput.keyboard import Controller as KeyboardController, Key

# ---------- Logging ----------

def setup_logger() -> logging.Logger:
    logger = logging.getLogger("magic")
    logger.setLevel(getattr(logging, LOG_LEVEL.upper(), logging.DEBUG))
    logger.propagate = False

    fmt = logging.Formatter(
        "%(asctime)s.%(msecs)03d %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    fh = RotatingFileHandler(LOG_FILE, maxBytes=LOG_MAX_BYTES, backupCount=LOG_BACKUPS, encoding="utf-8")
    fh.setFormatter(fmt)
    fh.setLevel(getattr(logging, LOG_LEVEL.upper(), logging.DEBUG))
    logger.addHandler(fh)

    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(fmt)
    ch.setLevel(getattr(logging, LOG_LEVEL.upper(), logging.DEBUG))
    logger.addHandler(ch)

    logger.info("=== Magic Control Server starting ===")
    logger.info("OS=%s", platform.platform())
    logger.info("Python=%s", sys.version.replace("\n", " "))
    logger.info("Listening=%s:%s", HOST, PORT)
    logger.info("Auth=%s", "ENABLED" if AUTH_BEARER_TOKEN else "DISABLED")
    logger.info("Profiles=%s", ",".join(PROFILE_GESTURE_MAPS.keys()))
    return logger

log = setup_logger()

# ---------- OS controllers ----------

mouse = MouseController()
keyboard = KeyboardController()

def now_ms() -> int:
    return int(time.time() * 1000)

def sleep_ms(ms: int) -> None:
    if ms > 0:
        time.sleep(ms / 1000.0)

# ---------- Models ----------

class ClickPayload(BaseModel):
    kind: str  # left/right/doubleLeft/dragStart/dragEnd

class GesturePayload(BaseModel):
    name: str
    confidence: Optional[float] = None
    meta: Optional[Dict[str, str]] = None

class CommandPayload(BaseModel):
    kind: str  # start/stop/panicStop/recenter/setProfile/setPointerMode/setDrag
    value: Optional[str] = None
    boolValue: Optional[bool] = None

class EventPayload(BaseModel):
    click: Optional[ClickPayload] = None
    gesture: Optional[GesturePayload] = None
    command: Optional[CommandPayload] = None

class EventRequest(BaseModel):
    deviceId: str = Field(..., alias="deviceId")
    profileId: str = Field(..., alias="profileId")
    seq: int
    tsMs: int = Field(..., alias="tsMs")
    type: str
    payload: EventPayload

class MotionSample(BaseModel):
    dtMs: int = Field(..., ge=0, le=65535)
    dx: float
    dy: float

class MotionRequest(BaseModel):
    deviceId: str = Field(..., alias="deviceId")
    profileId: str = Field(..., alias="profileId")
    seq: int
    tsMs: int = Field(..., alias="tsMs")
    mode: str
    samples: List[MotionSample]

# ---------- State ----------

class DeviceState:
    def __init__(self) -> None:
        self.last_seq_accepted: int = 0
        self.motion_enabled: bool = MOTION_ENABLED_DEFAULT
        self.drag_down: bool = False
        self.last_motion_at_ms: int = 0
        self.profile_id: str = "mouse"
        self.pointer_mode: str = "relative"

DEVICES: Dict[str, DeviceState] = {}

def get_device(device_id: str) -> DeviceState:
    if device_id not in DEVICES:
        DEVICES[device_id] = DeviceState()
        log.info("[device] registered device_id=%s", device_id)
    return DEVICES[device_id]

# ---------- Auth ----------

def check_auth(authorization: Optional[str]) -> None:
    if not AUTH_BEARER_TOKEN:
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing_bearer")
    token = authorization.split(" ", 1)[1].strip()
    if token != AUTH_BEARER_TOKEN:
        raise HTTPException(status_code=403, detail="invalid_token")

# ---------- Seq validation ----------

def validate_seq(ds: DeviceState, device_id: str, seq: int) -> bool:
    last = ds.last_seq_accepted

    if seq <= last:
        msg = f"[seq] DUP/OLD device={device_id} seq={seq} last={last}"
        if IGNORE_DUPLICATES:
            log.warning(msg + " -> ignored")
            return False
        log.warning(msg + " -> accepted (dup handling disabled)")
        return True

    if seq != last + 1:
        msg = f"[seq] GAP device={device_id} seq={seq} last={last}"
        if ALLOW_OUT_OF_ORDER_GAPS:
            log.warning(msg + " -> accepted")
            return True
        log.warning(msg + " -> rejected")
        return False

    return True

def accept_seq(ds: DeviceState, seq: int) -> None:
    ds.last_seq_accepted = max(ds.last_seq_accepted, seq)

# ---------- Actions (mouse/keyboard) ----------

def move_cursor_relative(dx: float, dy: float) -> Tuple[int, int]:
    sx = dx * MOTION_SCALE
    sy = dy * MOTION_SCALE

    if MOTION_ACCELERATION > 0:
        speed = min(50.0, (abs(sx) + abs(sy)) / 2.0)
        accel = 1.0 + (MOTION_ACCELERATION * (speed / 50.0))
        sx *= accel
        sy *= accel

    if MOTION_DEADZONE > 0:
        if abs(sx) < MOTION_DEADZONE: sx = 0
        if abs(sy) < MOTION_DEADZONE: sy = 0

    ix = int(round(sx))
    iy = int(round(sy))
    if ix != 0 or iy != 0:
        mouse.move(ix, iy)
    return ix, iy

def mouse_click(kind: str) -> None:
    if kind == "left":
        mouse.click(Button.left, 1)
    elif kind == "right":
        mouse.click(Button.right, 1)
    elif kind == "doubleLeft":
        mouse.click(Button.left, 2)
    elif kind == "dragStart":
        mouse.press(Button.left)
    elif kind == "dragEnd":
        mouse.release(Button.left)
    else:
        raise ValueError(f"unknown_click_kind:{kind}")

def set_drag(ds: DeviceState, enable: bool) -> None:
    if enable and not ds.drag_down:
        mouse.press(Button.left)
        ds.drag_down = True
    elif not enable and ds.drag_down:
        mouse.release(Button.left)
        ds.drag_down = False

KEY_ALIASES = {
    "cmd": Key.cmd, "command": Key.cmd,
    "ctrl": Key.ctrl, "control": Key.ctrl,
    "alt": Key.alt, "option": Key.alt,
    "shift": Key.shift,
    "enter": Key.enter,
    "esc": Key.esc,
    "tab": Key.tab,
    "space": Key.space,
    "up": Key.up, "down": Key.down, "left": Key.left, "right": Key.right,
    "backspace": Key.backspace,
    "delete": Key.delete,
    "home": Key.home,
    "end": Key.end,
    "pageup": Key.page_up,
    "pagedown": Key.page_down,
    "f5": Key.f5,
}

def _normalize_combo(combo: List[str]) -> List[Any]:
    out: List[Any] = []
    for k in combo:
        ks = str(k).strip()
        if not ks:
            continue
        # allow "shift+f5" style in config too
        if "+" in ks:
            parts = [p.strip() for p in ks.split("+") if p.strip()]
            for p in parts:
                out.append(KEY_ALIASES.get(p.lower(), p))
        else:
            out.append(KEY_ALIASES.get(ks.lower(), ks))
    return out

def press_combo(combo: List[str]) -> None:
    keys = _normalize_combo(combo)
    if not keys:
        return

    for k in keys:
        keyboard.press(k)
    sleep_ms(KEY_COMBO_PRESS_DELAY_MS)
    for k in reversed(keys):
        keyboard.release(k)

def type_text(value: str) -> None:
    for ch in value:
        keyboard.press(ch)
        keyboard.release(ch)

def scroll(amount: int) -> None:
    mouse.scroll(0, int(amount))

# ---------- Profile routing ----------

def resolve_profile(profile_id: str) -> str:
    pid = (profile_id or "").strip().lower()
    if pid in PROFILE_GESTURE_MAPS:
        return pid
    return "mouse"

def handle_gesture(ds: DeviceState, device_id: str, profile_id: str, name: str, confidence: Optional[float]) -> None:
    pid = resolve_profile(profile_id)
    gname = (name or "").strip()

    action = PROFILE_GESTURE_MAPS.get(pid, {}).get(gname)
    log.info("[gesture] device=%s profile=%s name=%s conf=%s action=%s",
             device_id, pid, gname, confidence, action)

    if not action:
        return

    t = action.get("type")
    if t == "click":
        button = action.get("button", "left")
        mouse_click("doubleLeft" if button == "doubleLeft" else button)
    elif t == "drag":
        state = action.get("state")
        if state == "start":
            set_drag(ds, True)
        elif state == "end":
            set_drag(ds, False)
    elif t == "scroll":
        scroll(int(action.get("amount", 1)))
    elif t == "key":
        combo = action.get("combo", [])
        press_combo(combo)
    elif t == "text":
        type_text(str(action.get("value", "")))
    elif t == "panic":
        if ALLOW_PANIC_STOP:
            ds.motion_enabled = False
            if PANIC_ALSO_RELEASE_DRAG:
                set_drag(ds, False)
            log.warning("[panic] device=%s -> motion disabled%s", device_id,
                        " + drag released" if PANIC_ALSO_RELEASE_DRAG else "")
    else:
        log.warning("[gesture] unknown action type=%s action=%s", t, action)

def handle_command(ds: DeviceState, device_id: str, cmd: CommandPayload) -> None:
    log.info("[command] device=%s kind=%s value=%s bool=%s",
             device_id, cmd.kind, cmd.value, cmd.boolValue)

    kind = (cmd.kind or "").strip()
    if kind == "start":
        ds.motion_enabled = True
    elif kind == "stop":
        ds.motion_enabled = False
        set_drag(ds, False)
    elif kind == "panicStop":
        if ALLOW_PANIC_STOP:
            ds.motion_enabled = False
            if PANIC_ALSO_RELEASE_DRAG:
                set_drag(ds, False)
    elif kind == "recenter":
        # Server can't "recenter" without absolute frame; treat as no-op.
        pass
    elif kind == "setProfile":
        if cmd.value:
            ds.profile_id = resolve_profile(cmd.value)
    elif kind == "setPointerMode":
        if cmd.value:
            ds.pointer_mode = cmd.value
    elif kind == "setDrag":
        if cmd.boolValue is not None:
            set_drag(ds, bool(cmd.boolValue))
    else:
        log.warning("[command] unknown kind=%s", kind)

# ---------- FastAPI app ----------

app = FastAPI()

def _client_ip(request: Request) -> str:
    # Prefer nginx forwarded headers if present
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    xri = request.headers.get("x-real-ip")
    if xri:
        return xri.strip()
    if request.client:
        return request.client.host
    return "unknown"

def _log_headers(headers) -> Dict[str, str]:
    out = {}
    for k, v in headers.items():
        lk = k.lower()
        if lk in LOG_HEADERS_WHITELIST:
            # mask auth token
            if lk == "authorization" and v.startswith("Bearer "):
                out[k] = "Bearer ***"
            else:
                out[k] = v
    return out

@app.middleware("http")
async def full_request_logger(request: Request, call_next):
    t0 = time.time()
    ip = _client_ip(request)
    method = request.method
    path = request.url.path

    # Read body (FastAPI allows re-inject)
    body_bytes = await request.body()
    body_preview = body_bytes[:LOG_MAX_BODY_BYTES]
    body_text = ""
    if body_preview:
        try:
            body_text = body_preview.decode("utf-8", errors="replace")
        except Exception:
            body_text = repr(body_preview)

    headers = _log_headers(request.headers)

    log.debug("[http.in] ip=%s %s %s headers=%s body=%s%s",
              ip, method, path, headers,
              body_text,
              "" if len(body_bytes) <= LOG_MAX_BODY_BYTES else f"...(+{len(body_bytes)-LOG_MAX_BODY_BYTES} bytes)")

    # Recreate request stream for downstream
    async def receive():
        return {"type": "http.request", "body": body_bytes, "more_body": False}

    request = Request(request.scope, receive)

    try:
        response = await call_next(request)
        dt = (time.time() - t0) * 1000.0
        log.debug("[http.out] ip=%s %s %s -> %s (%.1fms)", ip, method, path, response.status_code, dt)
        return response
    except Exception as e:
        dt = (time.time() - t0) * 1000.0
        log.exception("[http.err] ip=%s %s %s -> EXC (%.1fms): %s", ip, method, path, dt, e)
        raise

@app.get("/health")
async def health(authorization: Optional[str] = Header(default=None)):
    check_auth(authorization)
    last_seq = max((ds.last_seq_accepted for ds in DEVICES.values()), default=0)
    return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": last_seq}

@app.post("/event")
async def event(req: EventRequest, authorization: Optional[str] = Header(default=None)):
    check_auth(authorization)
    ds = get_device(req.deviceId)

    # keep device last-known profile/mode (useful for logs/telemetry)
    ds.profile_id = resolve_profile(req.profileId) or ds.profile_id

    accepted = validate_seq(ds, req.deviceId, req.seq)
    if not accepted:
        return {
            "ok": True,
            "server_ts_ms": now_ms(),
            "last_seq_accepted": ds.last_seq_accepted,
            "error_code": "duplicate_ignored",
        }

    try:
        etype = (req.type or "").strip()

        if etype == "click" and req.payload.click:
            kind = req.payload.click.kind
            log.info("[click] device=%s profile=%s seq=%s kind=%s",
                     req.deviceId, ds.profile_id, req.seq, kind)
            # native click behavior (can extend per profile later)
            mouse_click(kind)

        elif etype == "gesture" and req.payload.gesture:
            g = req.payload.gesture
            handle_gesture(ds, req.deviceId, ds.profile_id, g.name, g.confidence)

        elif etype == "command" and req.payload.command:
            handle_command(ds, req.deviceId, req.payload.command)

        else:
            log.warning("[event] bad payload device=%s seq=%s type=%s payload=%s",
                        req.deviceId, req.seq, req.type, req.payload.model_dump())

        accept_seq(ds, req.seq)
        return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": ds.last_seq_accepted}

    except Exception as e:
        log.exception("[event] EXEC ERROR device=%s seq=%s type=%s: %s", req.deviceId, req.seq, req.type, e)
        # Do NOT advance seq on failure: client can retry safely.
        return JSONResponse(
            status_code=500,
            content={
                "ok": False,
                "server_ts_ms": now_ms(),
                "last_seq_accepted": ds.last_seq_accepted,
                "error_code": "exec_error",
            },
        )

@app.post("/motion")
async def motion(req: MotionRequest, authorization: Optional[str] = Header(default=None)):
    check_auth(authorization)
    ds = get_device(req.deviceId)

    pid = resolve_profile(req.profileId)
    ds.profile_id = pid
    ds.pointer_mode = req.mode or ds.pointer_mode

    # If profile doesn't allow cursor movement, just ack and do nothing.
    if pid not in MOTION_PROFILE_ONLY:
        accept_seq(ds, req.seq)
        log.debug("[motion] ignored (profile=%s) device=%s seq=%s", pid, req.deviceId, req.seq)
        return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": ds.last_seq_accepted, "error_code": "motion_ignored_profile"}

    if req.seq <= ds.last_seq_accepted and IGNORE_DUPLICATES:
        log.debug("[motion] old seq ignored device=%s seq=%s last=%s", req.deviceId, req.seq, ds.last_seq_accepted)
        return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": ds.last_seq_accepted, "error_code": "old_motion_ignored"}

    if not ds.motion_enabled:
        log.debug("[motion] disabled device=%s seq=%s", req.deviceId, req.seq)
        accept_seq(ds, req.seq)
        return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": ds.last_seq_accepted, "error_code": "motion_disabled"}

    # Rate-limit per device
    now = now_ms()
    if now - ds.last_motion_at_ms < MOTION_MIN_INTERVAL_MS:
        accept_seq(ds, req.seq)
        log.debug("[motion] rate_limited device=%s seq=%s", req.deviceId, req.seq)
        return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": ds.last_seq_accepted, "error_code": "motion_rate_limited"}
    ds.last_motion_at_ms = now

    samples = req.samples[:MOTION_MAX_SAMPLES_PER_REQUEST]
    if not samples:
        accept_seq(ds, req.seq)
        return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": ds.last_seq_accepted}

    try:
        sum_dx = 0.0
        sum_dy = 0.0
        for s in samples:
            sum_dx += float(s.dx)
            sum_dy += float(s.dy)

        ix, iy = move_cursor_relative(sum_dx, sum_dy)

        log.debug("[motion] device=%s profile=%s mode=%s seq=%s n=%d sum_dx=%.3f sum_dy=%.3f px=(%d,%d)",
                  req.deviceId, pid, req.mode, req.seq, len(samples), sum_dx, sum_dy, ix, iy)

        accept_seq(ds, req.seq)
        return {"ok": True, "server_ts_ms": now_ms(), "last_seq_accepted": ds.last_seq_accepted}

    except Exception as e:
        log.exception("[motion] EXEC ERROR device=%s seq=%s: %s", req.deviceId, req.seq, e)
        return JSONResponse(
            status_code=500,
            content={
                "ok": False,
                "server_ts_ms": now_ms(),
                "last_seq_accepted": ds.last_seq_accepted,
                "error_code": "motion_exec_error",
            },
        )

# ---------- Main ----------

if __name__ == "__main__":
    import uvicorn
    # Uvicorn's own logging can be noisy; we log everything ourselves.
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
