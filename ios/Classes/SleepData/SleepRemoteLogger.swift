//
//  SleepRemoteLogger.swift
//  humango_health
//
//  Fire-and-forget remote logger for the background sleep pipeline.
//  Every call sends a structured JSON event to the Humango logging endpoint.
//  Network errors are non-fatal and never disrupt the sleep pipeline.
//

import Foundation

enum SleepLogLevel: String { case debug, info, warn, error }

struct SleepRemoteLogger {

    static let endpoint = URL(string: "https://humango-api-629346406456.us-central1.run.app/log")!

    /// Sends a single log event. Fire-and-forget — errors are silently ignored.
    static func log(
        _ level: SleepLogLevel,
        step: String,
        message: String,
        context: [String: Any] = [:]
    ) {
        var body: [String: Any] = [
            "platform":  "iOS",
            "subsystem": "SleepDataManager",
            "level":     level.rawValue,
            "step":      step,
            "message":   message,
            "dateTime":  ISO8601DateFormatter().string(from: Date()),
        ]

        // Attach user / app metadata when available
        if let userId = UserAuthStateManager.shared.userId {
            body["userId"] = userId
        }
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["appVersion"] = version
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            body["buildNumber"] = build
        }

        if !context.isEmpty {
            body["context"] = context
        }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
