//
//  SleepRemoteLogger.swift
//  humango_health
//
//  Fire-and-forget remote logger for the sleep background pipeline.
//  Sends structured log events to the Humango logging endpoint so that
//  background observer activity (which cannot be observed in Xcode console
//  in production) can be inspected server-side.
//
//  Usage:
//      await SleepRemoteLogger.shared.log(level: .info, message: "...", context: [...])
//
//  All calls are fire-and-forget: network failures are logged locally via
//  debugPrint and do NOT throw or block the caller.
//

import Foundation

// MARK: - Log Level

enum SleepLogLevel: String {
    case debug = "debug"
    case info  = "info"
    case warn  = "warn"
    case error = "error"
}

// MARK: - SleepRemoteLogger

class SleepRemoteLogger {
    static let shared = SleepRemoteLogger()

    private let endpoint = URL(string: "https://humango-api-629346406456.us-central1.run.app/log")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    // MARK: - Public API

    /// Sends a log event to the remote logging endpoint.
    ///
    /// - Parameters:
    ///   - level:   Severity — debug / info / warn / error
    ///   - message: Short human-readable summary (appears as the log line title)
    ///   - context: Arbitrary key-value pairs (all values must be JSON-serialisable)
    func log(
        level: SleepLogLevel,
        message: String,
        context: [String: Any] = [:]
    ) async {
        var ctx = context
        // Always attach common fields
        ctx["platform"]   = "iOS"
        ctx["subsystem"]  = "SleepBackground"
        ctx["dateTime"]   = isoFormatter.string(from: Date())
        ctx["userId"]     = UserAuthStateManager.shared.userId ?? "unknown"
        ctx["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ctx["buildNumber"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        let body: [String: Any] = [
            "level":   level.rawValue,
            "message": message,
            "context": ctx
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            debugPrint("🪵 [SleepRemoteLogger] serialization failed for: \(message)")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod  = "POST"
        request.httpBody    = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        debugPrint("🪵 [SleepRemoteLogger] [\(level.rawValue.uppercased())] \(message)")

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if !(200...299).contains(status) {
                debugPrint("🪵 [SleepRemoteLogger] server returned HTTP \(status) for: \(message)")
            }
        } catch {
            // Network failure is non-fatal — sleep pipeline must not be disrupted
            debugPrint("🪵 [SleepRemoteLogger] network error (\(error.localizedDescription)) for: \(message)")
        }
    }
}
