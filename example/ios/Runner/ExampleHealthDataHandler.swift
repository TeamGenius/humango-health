//
//  ExampleHealthDataHandler.swift
//  Runner (example app)
//
//  Concrete implementation of HumangoHealthDataDelegate for the example app.
//  Workouts are POSTed to POST /activities/{athleteId} using a fixed random
//  athleteId so the delegate flow can be verified end-to-end without a login.
//

import Foundation
import humango_health

final class ExampleHealthDataHandler: HumangoHealthDataDelegate {

    private let athleteId = "50739"

    private let apiBase = "https://humango-api-629346406456.us-central1.run.app"

    func onWorkoutReady(workout: HuWorkout, deviceId: String) async {
        print("[Example][Delegate] 🏃 Workout ready — deviceId=\(deviceId), sport=\(workout.sport.name), posting to /activities/\(athleteId)")
        guard let dict = workout.toDict(),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            print("[Example][Delegate] ❌ Failed to serialise HuWorkout for \(deviceId)")
            return
        }
        await postWorkout(json: json)
    }

    func onSleepSessionReady(json: String, sessionId: String) async {
        print("[Example][Delegate] 😴 Sleep session ready — sessionId=\(sessionId), posting to /sleep/\(athleteId)")
        logSleepPayload(json: json, sessionId: sessionId)
        await postSleep(json: json)
    }

    func onHealthMetricReady(payload: [String: Any], metricType: String) async {
        print("[Example][Delegate] 📊 Health metric ready — type=\(metricType), payload=\(payload)")
    }

    // MARK: - Remote Log

    private func logSleepPayload(json: String, sessionId: String) {
        guard let logURL = URL(string: "\(apiBase)/log") else { return }

        var body: [String: Any] = [
            "source":    "ExampleHealthDataHandler",
            "method":    "onSleepSessionReady",
            "sessionId": sessionId,
            "athleteId": athleteId,
            "dateTime":  ISO8601DateFormatter().string(from: Date()),
        ]

        // Embed the sleep payload as a nested object (not a raw string)
        if let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body["payload"] = parsed
        } else {
            body["payloadRaw"] = json
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: logURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Upload

    private func postWorkout(json: String) async {
        await post(path: "activities", json: json)
    }

    private func postSleep(json: String) async {
        await post(path: "sleep", json: json)
    }

    private func post(path: String, json: String) async {
        guard let url = URL(string: "\(apiBase)/\(path)/\(athleteId)"),
              let body = json.data(using: .utf8) else {
            print("[Example][Delegate] ❌ Invalid URL or JSON encoding failed")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody   = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Example][Delegate] ✅ POST /\(path)/\(athleteId) → HTTP \(status)")
        } catch {
            print("[Example][Delegate] ❌ POST /\(path)/\(athleteId) failed: \(error)")
        }
    }
}

