//
//  AppState.swift
//  Magic Control
//
//  Created by Владислав on 01.01.2026.
//
import SwiftUI
import Combine
import Foundation

// MARK: - UI Enums / Models

enum StatusDotState: Equatable {
    case green
    case yellow
    case red

    var color: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}

enum Profile: String, CaseIterable, Identifiable {
    case mouse
    case presentation
    case media
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mouse: return "Mouse"
        case .presentation: return "Presentation"
        case .media: return "Media"
        case .custom: return "Custom"
        }
    }
}

enum PointerMode: String, CaseIterable, Identifiable {
    case relative
    case clutch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relative: return "Relative"
        case .clutch: return "Clutch"
        }
    }
}

// MARK: - Network Models (shared with NetworkClient.swift)

struct NetResult: Sendable {
    let ok: Bool
    let latencyMs: Int
    let httpCode: Int?
    let lastSeqAccepted: UInt64?
    let errorCode: String?
}

enum EventType: String, Codable, Sendable {
    case command
    case click
    case gesture
}

enum ClickKind: String, Codable, Sendable {
    case left
    case right
    case doubleLeft
    case dragStart
    case dragEnd
}

enum CommandKind: String, Codable, Sendable {
    case start
    case stop
    case panicStop
    case recenter
    case setProfile
    case setPointerMode
    case setDrag
}

struct EventRequest: Codable, Sendable {
    let deviceId: String
    let profileId: String
    let seq: UInt64
    let tsMs: UInt64
    let type: EventType
    let payload: Payload

    struct Payload: Codable, Sendable {
        var click: ClickPayload?
        var gesture: GesturePayload?
        var command: CommandPayload?
    }

    struct ClickPayload: Codable, Sendable {
        let kind: ClickKind
    }

    struct GesturePayload: Codable, Sendable {
        let name: String
        let confidence: Double?
        let meta: [String: String]?
    }

    struct CommandPayload: Codable, Sendable {
        let kind: CommandKind
        let value: String?
        let boolValue: Bool?
    }
}

struct MotionRequest: Codable, Sendable {
    let deviceId: String
    let profileId: String
    let seq: UInt64
    let tsMs: UInt64
    let mode: String
    let samples: [Sample]

    struct Sample: Codable, Sendable {
        let dtMs: UInt16
        let dx: Float
        let dy: Float
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: Constants (single place)

    private let baseURLString = "https://magic.platoniks.ru"
    private let healthPath = "/health"
    private let eventPath = "/event"
    private let motionPath = "/motion"

    // Network behavior
    private let healthTimeoutMs: Int = 500
    private let criticalTimeoutMs: Int = 600
    private let motionTimeoutMs: Int = 600
    private let criticalRetries: Int = 2
    private let yellowMinHoldMs: UInt64 = 180 // avoids too-fast blinking

    // Motion behavior (high-level; detailed filtering in MotionAndGestures.swift)
    private let freezeAfterGestureMs: UInt64 = 160

    // MARK: Published (UI)

    @Published var statusDot: StatusDotState = .red
    @Published var isOnline: Bool = false
    @Published var isRunning: Bool = false

    @Published var profile: Profile = .mouse {
        didSet { Task { await sendProfileUpdate() } }
    }
    @Published var pointerMode: PointerMode = .relative {
        didSet { applyRuntimeConfig(); Task { await sendPointerModeUpdate() } }
    }

    @Published var sensitivity: Double = 1.4 {
        didSet { applyRuntimeConfig() }
    }
    @Published var smoothingEnabled: Bool = true {
        didSet { applyRuntimeConfig() }
    }

    @Published var lastGestureText: String = ""
    @Published var eventLog: [String] = []
    @Published var lastLatencyMs: Int? = nil
    @Published var lastPingText: String? = nil
    @Published var dragEnabled: Bool = false {
        didSet { Task { await sendDragUpdate() } }
    }

    // MARK: Derived UI labels

    var serverHostLabel: String { "https://magic.platoniks.ru" }

    // MARK: Internals

    private let deviceId: String = {
        // Stable-enough identifier for your own usage; can be replaced later
        "watch-" + (UUID().uuidString.prefix(8))
    }()

    private var seq: UInt64 = 1
    private var inflightCount: Int = 0 {
        didSet { updateStatusDotForInflight() }
    }

    private var lastOutcome: Bool? = nil
    private var lastSendBeganAtMs: UInt64 = 0

    private var criticalQueue: [EventRequest] = []
    private var isFlushingCriticalQueue: Bool = false

    // Dependencies (implemented in other files)
    private let net: NetworkClient
    private let motion: MotionAndGestures

    // MARK: Init

    init() {
        self.net = NetworkClient(
            baseURLString: baseURLString,
            healthPath: healthPath,
            eventPath: eventPath,
            motionPath: motionPath
        )

        self.motion = MotionAndGestures()
    }

    // MARK: Lifecycle

    func onLaunch() async {
        await ping()
    }

    // MARK: UI Actions

    func ping() async {
        beginRequest()
        defer { endRequestWillSetDot() }

        do {
            let res = try await net.health(timeoutMs: healthTimeoutMs)
            applyNetResult(res, label: "PING")
        } catch {
            applyError(label: "PING", error: error)
        }
    }

    func start() async {
        // If offline, try one ping first.
        if !isOnline {
            await ping()
        }
        guard isOnline else {
            addLog("START blocked: offline")
            return
        }

        // Send "start" as critical command
        await sendCommand(.start, value: nil, boolValue: nil)

        // Start motion/gesture capture
        isRunning = true
        addLog("Started")

        motion.start(
            pointerMode: pointerMode,
            sensitivity: Float(sensitivity),
            smoothingEnabled: smoothingEnabled,
            freezeAfterGestureMs: freezeAfterGestureMs,
            onMotion: { [weak self] batch in
                Task { await self?.handleMotionBatch(batch) }
            },
            onGesture: { [weak self] gesture in
                Task { await self?.handleGesture(gesture) }
            }
        )
    }

    func stop() async {
        motion.stop()
        isRunning = false
        addLog("Stopped")

        await sendCommand(.stop, value: nil, boolValue: nil)
    }

    func panicStop() async {
        motion.stop()
        isRunning = false
        criticalQueue.removeAll()
        addLog("PANIC STOP")

        await sendCommand(.panicStop, value: nil, boolValue: nil)
    }

    func quickClick() async {
        await sendClick(.left)
    }

    func quickRightClick() async {
        await sendClick(.right)
    }

    func toggleDrag() async {
        // Drag is modeled as a state (start/end)
        if dragEnabled {
            await sendClick(.dragEnd)
            dragEnabled = false
        } else {
            await sendClick(.dragStart)
            dragEnabled = true
        }
    }

    func recenter() async {
        await sendCommand(.recenter, value: nil, boolValue: nil)
    }

    /// Called from ContentView on slider/toggle changes.
    func applyRuntimeConfig() {
        motion.updateConfig(
            pointerMode: pointerMode,
            sensitivity: Float(sensitivity),
            smoothingEnabled: smoothingEnabled,
            freezeAfterGestureMs: freezeAfterGestureMs
        )
    }

    // MARK: Motion/Gesture Handlers

    private func handleGesture(_ gesture: GestureEvent) async {
        // Show in UI
        lastGestureText = gesture.displayName
        addLog("Gesture: \(gesture.displayName)")

        // Send as critical event
        await sendGesture(name: gesture.name, confidence: gesture.confidence, meta: gesture.meta)
    }

    private func handleMotionBatch(_ batch: MotionBatch) async {
        guard isRunning else { return }
        guard isOnline else { return }

        // Motion is non-critical: we send best-effort, no queue growth.
        let req = MotionRequest(
            deviceId: deviceId,
            profileId: profile.id,
            seq: nextSeq(),
            tsMs: nowMs(),
            mode: pointerMode.rawValue,
            samples: batch.samples.map {
                MotionRequest.Sample(dtMs: $0.dtMs, dx: $0.dx, dy: $0.dy)
            }
        )

        beginRequest()
        defer { endRequestWillSetDot() }

        do {
            let res = try await net.postMotion(req, timeoutMs: motionTimeoutMs)
            applyNetResult(res, label: "MOTION")
        } catch {
            // For motion: do not spam logs; just mark offline/outcome if network is gone.
            applyErrorSoft(label: "MOTION", error: error)
        }
    }

    // MARK: Critical sending (click/gesture/command)

    private func sendClick(_ kind: ClickKind) async {
        let req = EventRequest(
            deviceId: deviceId,
            profileId: profile.id,
            seq: nextSeq(),
            tsMs: nowMs(),
            type: .click,
            payload: .init(
                click: .init(kind: kind),
                gesture: nil,
                command: nil
            )
        )
        await enqueueCritical(req, label: "CLICK \(kind.rawValue)")
    }

    private func sendGesture(name: String, confidence: Double?, meta: [String: String]?) async {
        let req = EventRequest(
            deviceId: deviceId,
            profileId: profile.id,
            seq: nextSeq(),
            tsMs: nowMs(),
            type: .gesture,
            payload: .init(
                click: nil,
                gesture: .init(name: name, confidence: confidence, meta: meta),
                command: nil
            )
        )
        await enqueueCritical(req, label: "GESTURE \(name)")
    }

    private func sendCommand(_ kind: CommandKind, value: String?, boolValue: Bool?) async {
        let req = EventRequest(
            deviceId: deviceId,
            profileId: profile.id,
            seq: nextSeq(),
            tsMs: nowMs(),
            type: .command,
            payload: .init(
                click: nil,
                gesture: nil,
                command: .init(kind: kind, value: value, boolValue: boolValue)
            )
        )
        await enqueueCritical(req, label: "CMD \(kind.rawValue)")
    }

    private func sendProfileUpdate() async {
        await sendCommand(.setProfile, value: profile.id, boolValue: nil)
    }

    private func sendPointerModeUpdate() async {
        await sendCommand(.setPointerMode, value: pointerMode.rawValue, boolValue: nil)
    }

    private func sendDragUpdate() async {
        await sendCommand(.setDrag, value: nil, boolValue: dragEnabled)
    }

    private func enqueueCritical(_ req: EventRequest, label: String) async {
        criticalQueue.append(req)
        addLog(label)

        if !isFlushingCriticalQueue {
            await flushCriticalQueue()
        }
    }

    private func flushCriticalQueue() async {
        guard !isFlushingCriticalQueue else { return }
        isFlushingCriticalQueue = true
        defer { isFlushingCriticalQueue = false }

        while !criticalQueue.isEmpty {
            if !isOnline {
                // Try to restore connectivity once.
                await ping()
                if !isOnline { break }
            }

            let req = criticalQueue.removeFirst()
            let ok = await sendCriticalWithRetry(req)

            if !ok {
                // Put it back in front (do not lose), but avoid tight loop.
                criticalQueue.insert(req, at: 0)
                break
            }
        }
    }

    private func sendCriticalWithRetry(_ req: EventRequest) async -> Bool {
        var attempt = 0
        while attempt <= criticalRetries {
            attempt += 1

            beginRequest()
            defer { endRequestWillSetDot() }

            do {
                let res = try await net.postEvent(req, timeoutMs: criticalTimeoutMs)
                applyNetResult(res, label: "EVENT")

                if res.ok {
                    return true
                }
            } catch {
                applyError(label: "EVENT", error: error)
            }
        }
        return false
    }

    // MARK: Status dot + logging

    private func beginRequest() {
        inflightCount += 1
        lastSendBeganAtMs = nowMs()
        statusDot = .yellow
    }

    private func endRequestWillSetDot() {
        // hold yellow briefly to avoid blinkiness
        let elapsed = nowMs() &- lastSendBeganAtMs
        let remain = (elapsed >= yellowMinHoldMs) ? 0 : (yellowMinHoldMs - elapsed)

        Task { [weak self] in
            guard let self else { return }
            if remain > 0 {
                try? await Task.sleep(nanoseconds: remain * 1_000_000)
            }
            self.inflightCount = max(0, self.inflightCount - 1)
        }
    }

    private func updateStatusDotForInflight() {
        if inflightCount > 0 {
            statusDot = .yellow
            return
        }
        // No inflight -> show last outcome
        if lastOutcome == true {
            statusDot = .green
        } else if lastOutcome == false {
            statusDot = .red
        } else {
            statusDot = isOnline ? .green : .red
        }
    }

    private func applyNetResult(_ res: NetResult, label: String) {
        lastOutcome = res.ok
        lastLatencyMs = res.latencyMs
        isOnline = res.ok || (res.httpCode != nil) // server reachable even if business "ok" false
        if label == "PING" {
            lastPingText = "\(res.latencyMs)ms"
        }
    }

    private func applyError(label: String, error: Error) {
        lastOutcome = false
        isOnline = false
        if label == "PING" {
            lastPingText = "error"
        }
        addLog("\(label) error")
    }

    /// Softer error for high-frequency motion.
    private func applyErrorSoft(label: String, error: Error) {
        lastOutcome = false
        // keep isOnline as-is unless it looks like network died
        // (NetworkClient will normally throw URLError.notConnectedToInternet, timedOut, etc.)
        // We keep it simple here:
        isOnline = false
    }

    private func addLog(_ text: String) {
        let line = "\(timeHHmmss())  \(text)"
        eventLog.insert(line, at: 0)
        if eventLog.count > 30 { eventLog.removeLast(eventLog.count - 30) }
    }

    // MARK: Helpers

    private func nextSeq() -> UInt64 {
        defer { seq &+= 1 }
        return seq
    }

    private func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    private func timeHHmmss() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
