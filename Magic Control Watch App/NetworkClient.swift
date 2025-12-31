//
//  NetworkClient.swift
//  Magic Control
//
//  Created by Владислав on 01.01.2026.
//
import Foundation

final class NetworkClient {

    // MARK: - Config

    private let baseURL: URL
    private let healthPath: String
    private let eventPath: String
    private let motionPath: String

    /// Set later if you decide to protect the API.
    var bearerToken: String? = nil

    private let session: URLSession

    init(baseURLString: String, healthPath: String, eventPath: String, motionPath: String) {
        guard let url = URL(string: baseURLString) else {
            fatalError("Invalid baseURLString: \(baseURLString)")
        }
        self.baseURL = url
        self.healthPath = healthPath
        self.eventPath = eventPath
        self.motionPath = motionPath

        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil

        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public API

    func health(timeoutMs: Int) async throws -> NetResult {
        let _: HealthResponse = try await requestJSON(
            method: "GET",
            path: healthPath,
            body: Optional<Data>.none,
            timeoutMs: timeoutMs
        )
        // If we got a 2xx and JSON decoded, we treat as ok=true.
        return NetResult(ok: true, latencyMs: lastLatencyMs, httpCode: lastHttpCode, lastSeqAccepted: lastSeqAccepted, errorCode: nil)
    }

    func postEvent(_ req: EventRequest, timeoutMs: Int) async throws -> NetResult {
        let data = try JSONEncoder().encode(req)
        let _: GenericResponse = try await requestJSON(
            method: "POST",
            path: eventPath,
            body: data,
            timeoutMs: timeoutMs
        )
        return NetResult(ok: true, latencyMs: lastLatencyMs, httpCode: lastHttpCode, lastSeqAccepted: lastSeqAccepted, errorCode: nil)
    }

    func postMotion(_ req: MotionRequest, timeoutMs: Int) async throws -> NetResult {
        let data = try JSONEncoder().encode(req)
        let _: GenericResponse = try await requestJSON(
            method: "POST",
            path: motionPath,
            body: data,
            timeoutMs: timeoutMs
        )
        return NetResult(ok: true, latencyMs: lastLatencyMs, httpCode: lastHttpCode, lastSeqAccepted: lastSeqAccepted, errorCode: nil)
    }

    // MARK: - Internal JSON plumbing

    // These are set per request by requestJSON (simple way to return latency + httpCode
    // without duplicating code; safe because NetworkClient is a struct value, used from AppState single-threaded).
    private var lastLatencyMs: Int = 0
    private var lastHttpCode: Int? = nil
    private var lastSeqAccepted: UInt64? = nil

    @discardableResult
    private func requestJSON<T: Decodable>(
        method: String,
        path: String,
        body: Data?,
        timeoutMs: Int
    ) async throws -> T {

        var url = baseURL
        // Preserve any existing path on baseURL if needed, then append endpoint path.
        // baseURL is "https://magic.platoniks.ru" (no path), so this is safe.
        url.append(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "" : path)

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = TimeInterval(Double(timeoutMs) / 1000.0)

        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token = bearerToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body

        let start = DispatchTime.now()
        let (data, response) = try await session.data(for: req)
        let end = DispatchTime.now()

        let latency = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        lastLatencyMs = max(0, Int(latency.rounded()))
        lastHttpCode = (response as? HTTPURLResponse)?.statusCode

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            // Try to parse server error payload
            if let parsed = try? JSONDecoder().decode(GenericResponse.self, from: data) {
                lastSeqAccepted = parsed.last_seq_accepted
                throw ServerError.http(code: http.statusCode, message: parsed.error_code ?? "http_error")
            } else {
                throw ServerError.http(code: http.statusCode, message: "http_error")
            }
        }

        // Some endpoints might return empty body; support that.
        if data.isEmpty {
            // If T can be decoded from "{}"
            if let empty = "{}".data(using: .utf8), let obj = try? JSONDecoder().decode(T.self, from: empty) {
                return obj
            }
            // Otherwise, fail explicitly
            throw ServerError.decode(message: "Empty response")
        }

        let decoded = try JSONDecoder().decode(T.self, from: data)

        // If the response contains last_seq_accepted, store it
        if let generic = decoded as? GenericResponse {
            lastSeqAccepted = generic.last_seq_accepted
        } else if let health = decoded as? HealthResponse {
            lastSeqAccepted = health.last_seq_accepted
        }

        return decoded
    }
}

// MARK: - Responses

private struct GenericResponse: Decodable {
    let ok: Bool?
    let server_ts_ms: UInt64?
    let last_seq_accepted: UInt64?
    let error_code: String?
}

private struct HealthResponse: Decodable {
    let ok: Bool?
    let server_ts_ms: UInt64?
    let last_seq_accepted: UInt64?
}

// MARK: - Errors

enum ServerError: Error {
    case http(code: Int, message: String)
    case decode(message: String)
}
