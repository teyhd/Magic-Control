import Foundation
import CoreMotion

// MARK: - Public Models (used by AppState)

struct MotionSample {
    let dtMs: UInt16
    let dx: Float
    let dy: Float
}

struct MotionBatch {
    let samples: [MotionSample]
}

struct GestureEvent {
    let name: String
    let confidence: Double
    let meta: [String: String]?

    var displayName: String {
        if confidence >= 0.99 { return name }
        return "\(name) (\(String(format: "%.2f", confidence)))"
    }
}

// MARK: - MotionAndGestures

final class MotionAndGestures {

    // MARK: Serial work queue (CRITICAL: all state lives here)
    private let workQueue = DispatchQueue(label: "magic.motion.work", qos: .userInteractive)

    // MARK: Config (access only on workQueue)
    private var pointerMode: PointerMode = .relative
    private var sensitivity: Float = 1.4
    private var smoothingEnabled: Bool = true
    private var freezeAfterGestureMs: UInt64 = 160

    // Motion rates / batching
    private let motionHz: Double = 50.0
    private let batchFlushMs: UInt64 = 80
    private let maxSamplesPerBatch: Int = 24

    // Gesture thresholds (heuristic)
    private let flickAccelThreshold: Double = 1.2
    private let shakeAccelThreshold: Double = 2.0
    private let rotateRateThreshold: Double = 3.0
    private let gestureCooldownMs: UInt64 = 350

    // MARK: State (access only on workQueue)
    private let motionManager = CMMotionManager()
    private var isRunning: Bool = false

    private var onMotion: ((MotionBatch) -> Void)?
    private var onGesture: ((GestureEvent) -> Void)?

    private var motionTimer: DispatchSourceTimer?
    private var flushTimer: DispatchSourceTimer?

    private var pendingSamples: [MotionSample] = []
    private var lastTickAtMs: UInt64 = 0

    // gesture gating
    private var lastGestureAtMs: UInt64 = 0
    private var freezeUntilMs: UInt64 = 0

    // smoothing
    private var emaDx: Float = 0
    private var emaDy: Float = 0
    private let emaAlpha: Float = 0.35

    // clutch gating (pinch-hold)
    private var clutchPressed: Bool = false

    // MARK: Public API

    func start(
        pointerMode: PointerMode,
        sensitivity: Float,
        smoothingEnabled: Bool,
        freezeAfterGestureMs: UInt64,
        onMotion: @escaping (MotionBatch) -> Void,
        onGesture: @escaping (GestureEvent) -> Void
    ) {
        // Stop previous safely
        stop()

        workQueue.async { [weak self] in
            guard let self else { return }

            self.pointerMode = pointerMode
            self.sensitivity = sensitivity
            self.smoothingEnabled = smoothingEnabled
            self.freezeAfterGestureMs = freezeAfterGestureMs
            self.onMotion = onMotion
            self.onGesture = onGesture

            self.isRunning = true
            self.pendingSamples.removeAll(keepingCapacity: true)
            self.emaDx = 0
            self.emaDy = 0
            self.lastGestureAtMs = 0
            self.freezeUntilMs = 0

            let now = self.nowMs()
            self.lastTickAtMs = now

            guard self.motionManager.isDeviceMotionAvailable else {
                self.emitGestureOnMain(name: "motion_unavailable", confidence: 1.0, meta: nil)
                self.isRunning = false
                return
            }

            self.motionManager.deviceMotionUpdateInterval = 1.0 / self.motionHz
            self.motionManager.startDeviceMotionUpdates()

            // Tick timer (same serial queue)
            let tick = DispatchSource.makeTimerSource(queue: self.workQueue)
            tick.schedule(deadline: .now(), repeating: 1.0 / self.motionHz, leeway: .milliseconds(2))
            tick.setEventHandler { [weak self] in
                self?.tick()
            }
            tick.resume()
            self.motionTimer = tick

            // Flush timer (same serial queue)
            let flush = DispatchSource.makeTimerSource(queue: self.workQueue)
            flush.schedule(deadline: .now() + .milliseconds(Int(self.batchFlushMs)),
                           repeating: .milliseconds(Int(self.batchFlushMs)),
                           leeway: .milliseconds(4))
            flush.setEventHandler { [weak self] in
                self?.flushMotionLocked()
            }
            flush.resume()
            self.flushTimer = flush
        }
    }

    func stop() {
        workQueue.async { [weak self] in
            guard let self else { return }
            if !self.isRunning && self.motionTimer == nil && self.flushTimer == nil { return }

            self.isRunning = false

            self.motionTimer?.cancel()
            self.motionTimer = nil

            self.flushTimer?.cancel()
            self.flushTimer = nil

            if self.motionManager.isDeviceMotionActive {
                self.motionManager.stopDeviceMotionUpdates()
            }

            self.pendingSamples.removeAll(keepingCapacity: true)

            self.onMotion = nil
            self.onGesture = nil

            self.clutchPressed = false
            self.freezeUntilMs = 0
            self.lastGestureAtMs = 0
        }
    }

    func updateConfig(
        pointerMode: PointerMode,
        sensitivity: Float,
        smoothingEnabled: Bool,
        freezeAfterGestureMs: UInt64
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.pointerMode = pointerMode
            self.sensitivity = sensitivity
            self.smoothingEnabled = smoothingEnabled
            self.freezeAfterGestureMs = freezeAfterGestureMs
        }
    }

    // MARK: Pinch hooks (integration point)

    /// Wire real pinch event here later.
    func externalPinch() {
        workQueue.async { [weak self] in
            self?.emitGesture(name: "pinch", confidence: 1.0, meta: nil)
        }
    }

    /// Wire pinch-hold start/end here later (for Clutch).
    func externalPinchHold(isDown: Bool) {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.clutchPressed = isDown
            self.emitGesture(name: isDown ? "pinch_hold_start" : "pinch_hold_end", confidence: 1.0, meta: nil)
        }
    }

    // MARK: - Internal (runs only on workQueue)

    private func tick() {
        guard isRunning else { return }
        guard let dm = motionManager.deviceMotion else { return }

        let now = nowMs()
        let dt = now > lastTickAtMs ? (now - lastTickAtMs) : 0
        lastTickAtMs = now

        // 1) Detect gestures (may freeze motion)
        detectGestures(deviceMotion: dm, nowMs: now)

        // 2) Gate motion (freeze/clutch)
        if now < freezeUntilMs { return }
        if pointerMode == .clutch && !clutchPressed { return }

        // 3) Build dx/dy from rotationRate (more stable than accel)
        let rx = dm.rotationRate.x
        let ry = dm.rotationRate.y

        var dx = Float(ry) * sensitivity
        var dy = Float(-rx) * sensitivity

        // smoothing
        if smoothingEnabled {
            emaDx = emaDx + emaAlpha * (dx - emaDx)
            emaDy = emaDy + emaAlpha * (dy - emaDy)
            dx = emaDx
            dy = emaDy
        }

        // dead-zone
        let dead: Float = 0.02
        if abs(dx) < dead { dx = 0 }
        if abs(dy) < dead { dy = 0 }
        if dx == 0 && dy == 0 { return }

        let dtMs = UInt16(min(dt, UInt64(UInt16.max)))
        pendingSamples.append(MotionSample(dtMs: dtMs, dx: dx, dy: dy))

        if pendingSamples.count >= maxSamplesPerBatch {
            flushMotionLocked()
        }
    }

    private func flushMotionLocked() {
        guard isRunning else { return }
        guard let onMotion else { return }
        guard !pendingSamples.isEmpty else { return }

        let batch = MotionBatch(samples: pendingSamples)
        pendingSamples.removeAll(keepingCapacity: true)

        DispatchQueue.main.async {
            onMotion(batch)
        }
    }

    private func detectGestures(deviceMotion dm: CMDeviceMotion, nowMs now: UInt64) {
        if now < lastGestureAtMs + gestureCooldownMs { return }

        let ax = dm.userAcceleration.x
        let ay = dm.userAcceleration.y
        let az = dm.userAcceleration.z
        let absA = max(abs(ax), max(abs(ay), abs(az)))

        // Shake
        if absA > shakeAccelThreshold {
            fireGesture(name: "shake", confidence: confidence(absA, base: shakeAccelThreshold))
            return
        }

        // Flicks
        if abs(ax) > flickAccelThreshold || abs(ay) > flickAccelThreshold {
            if abs(ax) > abs(ay) {
                fireGesture(name: ax > 0 ? "flick_right" : "flick_left",
                            confidence: confidence(abs(ax), base: flickAccelThreshold))
            } else {
                fireGesture(name: ay > 0 ? "flick_up" : "flick_down",
                            confidence: confidence(abs(ay), base: flickAccelThreshold))
            }
            return
        }

        // Rotate
        let rz = dm.rotationRate.z
        if abs(rz) > rotateRateThreshold {
            fireGesture(name: rz > 0 ? "rotate_cw" : "rotate_ccw",
                        confidence: confidence(abs(rz), base: rotateRateThreshold))
            return
        }
    }

    private func fireGesture(name: String, confidence: Double) {
        let t = nowMs()
        lastGestureAtMs = t
        freezeUntilMs = t + freezeAfterGestureMs
        emitGesture(name: name, confidence: confidence, meta: nil)
    }

    private func emitGesture(name: String, confidence: Double, meta: [String: String]?) {
        guard let onGesture else { return }
        let ev = GestureEvent(name: name, confidence: confidence, meta: meta)
        DispatchQueue.main.async {
            onGesture(ev)
        }
    }

    private func emitGestureOnMain(name: String, confidence: Double, meta: [String: String]?) {
        guard let onGesture else { return }
        let ev = GestureEvent(name: name, confidence: confidence, meta: meta)
        DispatchQueue.main.async {
            onGesture(ev)
        }
    }

    private func confidence(_ value: Double, base: Double) -> Double {
        let x = min(1.0, max(0.0, (value - base) / (base * 1.5)))
        return 0.75 + 0.25 * x
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
