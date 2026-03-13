//
//  SleepBackgroundDeliveryManager.swift
//  humango_health
//
//  Manages background delivery of finalized sleep session data.
//  Supports two modes:
//  - `.api`: POSTs sleep data directly to a configured API endpoint (no foreground streaming)
//  - `.localStorage`: Default behavior — foreground live streaming + background UserDefaults storage
//
//  Mirrors the WorkoutReading/BackgroundDeliveryManager pattern.
//

import Foundation

// MARK: - Sleep Background Delivery Mode

@available(iOS 14.0, *)
enum SleepBackgroundDeliveryMode: String, Codable {
    /// API mode: sleep session data is POSTed directly to a remote API.
    /// No foreground live streaming occurs in this mode.
    case api
    
    /// Local storage mode (default): foreground uses EventChannel streaming,
    /// background stores to UserDefaults for later retrieval.
    case localStorage
}

// MARK: - UserDefaults Keys

private struct SleepDeliveryKeys {
    static let mode = "com.humango.health.sleepDeliveryMode"
    static let apiURL = "com.humango.health.sleepDeliveryURL"
    static let headers = "com.humango.health.sleepDeliveryHeaders"
    static let pendingLocalSleep = "com.humango.health.sleepPendingLocal"
}

// MARK: - SleepBackgroundDeliveryManager

@available(iOS 14.0, *)
class SleepBackgroundDeliveryManager {
    static let shared = SleepBackgroundDeliveryManager()
    
    private(set) var mode: SleepBackgroundDeliveryMode = .localStorage
    private var apiURL: URL?
    private var headers: [String: String] = [:]
    
    private init() {
        // Restore persisted configuration
        if let savedModeStr = UserDefaults.standard.string(forKey: SleepDeliveryKeys.mode),
           let savedMode = SleepBackgroundDeliveryMode(rawValue: savedModeStr) {
            self.mode = savedMode
            self.apiURL = UserDefaults.standard.url(forKey: SleepDeliveryKeys.apiURL)
            self.headers = UserDefaults.standard.dictionary(forKey: SleepDeliveryKeys.headers) as? [String: String] ?? [:]
            print("🛏️ [SleepDelivery] Restored config: mode=\(savedMode.rawValue), url=\(self.apiURL?.absoluteString ?? "nil")")
        }
    }
    
    /// Whether API delivery is fully configured (mode=.api AND apiURL is set).
    /// Used by auto-start logic to determine if monitoring should begin on app launch.
    var isAPIConfigured: Bool {
        return mode == .api && apiURL != nil
    }
    
    // MARK: - Configuration
    
    /// Configures the sleep background delivery mode.
    ///
    /// - Parameters:
    ///   - mode: `.api` for direct API delivery, `.localStorage` for default behavior
    ///   - apiURL: The API endpoint URL (required for `.api` mode)
    ///   - headers: Custom HTTP headers for API requests (e.g., auth tokens)
    func configure(mode: SleepBackgroundDeliveryMode, apiURL: URL?, headers: [String: String]) {
        self.mode = mode
        self.apiURL = apiURL
        self.headers = headers
        
        // Persist to UserDefaults
        UserDefaults.standard.set(mode.rawValue, forKey: SleepDeliveryKeys.mode)
        UserDefaults.standard.set(apiURL, forKey: SleepDeliveryKeys.apiURL)
        UserDefaults.standard.set(headers, forKey: SleepDeliveryKeys.headers)
        UserDefaults.standard.synchronize()
        
        print("🛏️ [SleepDelivery] Configured: mode=\(mode.rawValue), url=\(apiURL?.absoluteString ?? "nil"), headers=\(headers.count) keys")
    }

    /// Clears all persisted background delivery configuration.
    /// Called on user logout so sleep monitoring does not auto-restart on the next app launch.
    func clearConfiguration() {
        mode = .localStorage
        apiURL = nil
        headers = [:]
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.mode)
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.apiURL)
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.headers)
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.pendingLocalSleep)
        UserDefaults.standard.synchronize()
        print("🔐 [SleepDelivery] Cleared background delivery configuration on logout")
    }
    
    // MARK: - Deliver Sleep Session
    
    /// Delivers a finalized sleep session based on the configured mode.
    ///
    /// - Parameters:
    ///   - sleepDataJSON: JSON string of the full sleep session data
    ///   - sessionId: Unique identifier for this session (e.g., session start date)
    func deliverSleepSession(_ sleepDataJSON: String, sessionId: String) async {
        print("🛏️ [SleepDelivery] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🛏️ [SleepDelivery] Delivering sleep session: sessionId=\(sessionId)")
        print("🛏️ [SleepDelivery] Mode: \(mode.rawValue)")
        print("🛏️ [SleepDelivery] JSON size: \(sleepDataJSON.count) chars / \(sleepDataJSON.data(using: .utf8)?.count ?? 0) bytes")
        print("🛏️ [SleepDelivery] JSON preview: \(String(sleepDataJSON.prefix(500)))...")
        print("🛏️ [SleepDelivery] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        switch mode {
        case .api:
            // API mode: always push to API regardless of foreground/background
            print("🛏️ [SleepDelivery] API mode — pushing session \(sessionId) to API")
            await pushToAPI(sleepDataJSON, sessionId: sessionId)
            
        case .localStorage:
            // localStorage mode: store locally for retrieval via getLocalSleepSessions()
            print("🛏️ [SleepDelivery] localStorage mode — storing session \(sessionId) locally")
            storeLocally(sleepDataJSON)
        }
    }
    
    // MARK: - API Push
    
    /// POSTs the sleep session JSON to the configured API endpoint.
    private func pushToAPI(_ sleepJSON: String, sessionId: String) async {
        guard let url = apiURL else {
            print("⚠️ [SleepDelivery] API push failed: No API URL configured")
            storeLocally(sleepJSON)
            return
        }
        
        guard let data = sleepJSON.data(using: .utf8) else {
            print("⚠️ [SleepDelivery] API push failed: Cannot encode JSON to UTF8 data")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Apply custom headers (e.g., authorization)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Log API call details
        print("🌐 [SleepDelivery] ── API REQUEST ──────────────────────────")
        print("🌐 [SleepDelivery] URL: \(url.absoluteString)")
        print("🌐 [SleepDelivery] Method: POST")
        print("🌐 [SleepDelivery] Headers:")
        print("🌐 [SleepDelivery]   Content-Type: application/json")
        for (key, value) in headers {
            let maskedValue = key.lowercased().contains("auth") ? "\(value.prefix(10))...***" : value
            print("🌐 [SleepDelivery]   \(key): \(maskedValue)")
        }
        print("🌐 [SleepDelivery] Body size: \(data.count) bytes")
        print("🌐 [SleepDelivery] Body preview: \(String(sleepJSON.prefix(300)))...")
        print("🌐 [SleepDelivery] SessionId: \(sessionId)")
        print("🌐 [SleepDelivery] Sending request...")
        
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
            
            print("🌐 [SleepDelivery] ── API RESPONSE ─────────────────────────")
            print("🌐 [SleepDelivery] Status: \(statusCode)")
            print("🌐 [SleepDelivery] Response body: \(String(responseBody.prefix(500)))")
            
            if (200...299).contains(statusCode) {
                print("✅ [SleepDelivery] API push succeeded for session \(sessionId) (HTTP \(statusCode))")
            } else {
                print("⚠️ [SleepDelivery] API push failed with HTTP \(statusCode) for session \(sessionId) — storing locally as fallback")
                storeLocally(sleepJSON)
            }
        } catch {
            print("❌ [SleepDelivery] API push network error for session \(sessionId): \(error)")
            print("❌ [SleepDelivery] Error type: \(type(of: error)), description: \(error.localizedDescription)")
            storeLocally(sleepJSON)
        }
    }
    
    // MARK: - Local Storage
    
    /// Stores sleep session JSON in UserDefaults for later retrieval.
    private func storeLocally(_ sleepJSON: String) {
        var existing = UserDefaults.standard.stringArray(forKey: SleepDeliveryKeys.pendingLocalSleep) ?? []
        existing.append(sleepJSON)
        UserDefaults.standard.set(existing, forKey: SleepDeliveryKeys.pendingLocalSleep)
        UserDefaults.standard.synchronize()
        print("💾 [SleepDelivery] Stored sleep session locally. Total pending: \(existing.count)")
    }
    
    /// Retrieves and clears all locally stored sleep sessions.
    /// Call this from Flutter after app becomes active to retrieve background-collected data.
    func retrieveLocalSleepSessions() -> [String] {
        let sessions = UserDefaults.standard.stringArray(forKey: SleepDeliveryKeys.pendingLocalSleep) ?? []
        UserDefaults.standard.removeObject(forKey: SleepDeliveryKeys.pendingLocalSleep)
        UserDefaults.standard.synchronize()
        if !sessions.isEmpty {
            print("🛏️ [SleepDelivery] Retrieved \(sessions.count) locally stored sleep sessions")
        }
        return sessions
    }
}
