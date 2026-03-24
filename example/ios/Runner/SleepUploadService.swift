//
//  SleepUploadService.swift
//  Runner (example app)
//
//  Drains the humango_health sleep pending queue and POSTs each payload to
//  POST /sleep/{athleteId}
//
//  Credentials are read from UserDefaults under the same keys that Dart
//  `shared_preferences` writes (flutter. prefix), so the example-app UI
//  just sets them once and both Dart and native paths see them.
//
//  Usage:
//    await SleepUploadService.shared.uploadPending()
//
//  Failures are written back to UserDefaults so the next resume attempt retries.
//

import Foundation

final class SleepUploadService {
    static let shared = SleepUploadService()

    private let sleepKey    = "com.humango.health.sleepPendingLocal"
    /// Sessions moved here after a successful POST so Flutter can display them
    /// without re-uploading. Read-and-cleared by `getUploadedSleepSessions`.
    private let uploadedKey = "com.humango.health.sleepUploadedLocal"
    private let apiHost     = "https://humango-api-629346406456.us-central1.run.app"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - Credential helpers (aligned with NativeHealthBackendService key set)

    private func readAthleteId() -> Int? {
        let d = UserDefaults.standard
        for key in ["flutter.athlete_id", "athlete_id"] {
            if let v = d.object(forKey: key) {
                if let i = v as? Int { return i }
                if let s = v as? String, let i = Int(s) { return i }
            }
        }
        return nil
    }

    private func readAccessToken() -> String? {
        let d = UserDefaults.standard
        for key in ["flutter.access_token", "access_token"] {
            if let v = d.string(forKey: key), !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: - Upload

    /// Reads the pending sleep queue, POSTs each JSON to `/sleep/{athleteId}`,
    /// writes failures back to UserDefaults for retry on next call.
    ///
    /// Returns the number of successfully uploaded sessions.
    @discardableResult
    func uploadPending() async -> Int {
        guard let athleteId = readAthleteId() else {
            print("[Example][SleepUpload] skipped — no athleteId in UserDefaults")
            return 0
        }

        let d = UserDefaults.standard
        guard let pending = d.stringArray(forKey: sleepKey), !pending.isEmpty else {
            return 0
        }

        let urlString = "\(apiHost)/sleep/\(athleteId)"
        guard let url = URL(string: urlString) else {
            print("[Example][SleepUpload] invalid URL: \(urlString)")
            return 0
        }

        let token = readAccessToken()
        var successCount = 0
        var failedPayloads: [String] = []

        print("[Example][SleepUpload] uploading \(pending.count) session(s) → \(urlString)")

        for json in pending {
            guard let body = json.data(using: .utf8) else {
                failedPayloads.append(json)
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody   = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let t = token, !t.isEmpty {
                request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if (200...299).contains(status) {
                    successCount += 1
                    print("[Example][SleepUpload] ✅ session uploaded (HTTP \(status))")
                    // Mark as pushed so Flutter can display without re-uploading.
                    var uploaded = d.stringArray(forKey: uploadedKey) ?? []
                    uploaded.append(json)
                    d.set(uploaded, forKey: uploadedKey)
                } else {
                    print("[Example][SleepUpload] ⚠️ server returned HTTP \(status) — queued for retry")
                    failedPayloads.append(json)
                }
            } catch {
                print("[Example][SleepUpload] ❌ network error: \(error.localizedDescription) — queued for retry")
                failedPayloads.append(json)
            }
        }

        // Write back only the failures; successes are consumed.
        if failedPayloads.isEmpty {
            d.removeObject(forKey: sleepKey)
        } else {
            d.set(failedPayloads, forKey: sleepKey)
        }
        d.synchronize()

        print("[Example][SleepUpload] done — uploaded=\(successCount) failed=\(failedPayloads.count)")
        return successCount
    }
}
