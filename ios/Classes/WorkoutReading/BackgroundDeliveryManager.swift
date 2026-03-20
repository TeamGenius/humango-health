import Foundation
import Flutter

@available(iOS 13.0, *)
enum BackgroundDeliveryMode: String, Codable {
    case api
    case localStorage
}

@available(iOS 13.0, *)
class BackgroundDeliveryManager {
    static let shared = BackgroundDeliveryManager()
    
    private(set) var mode: BackgroundDeliveryMode = .localStorage
    private var apiURL: URL?
    private var headers: [String: String] = [:]
    
    /// Whether API delivery is fully configured (mode=.api AND apiURL is set).
    /// Used by auto-start logic to determine if monitoring should begin on app launch.
    var isAPIConfigured: Bool {
        return mode == .api && apiURL != nil
    }
    
    // Store eventSink to pump foreground events directly back to Flutter
    private var eventSink: FlutterEventSink?
    
    private init() {
        // Load saved configuration from defaults if it exists
        if let savedModeStr = UserDefaults.standard.string(forKey: "HumangoDeliveryMode"),
           let savedMode = BackgroundDeliveryMode(rawValue: savedModeStr) {
            self.mode = savedMode
            self.apiURL = UserDefaults.standard.url(forKey: "HumangoDeliveryURL")
            self.headers = UserDefaults.standard.dictionary(forKey: "HumangoDeliveryHeaders") as? [String: String] ?? [:]
        }
    }
    
    func attachEventSink(_ sink: FlutterEventSink?) {
        self.eventSink = sink
        if sink != nil {
            debugPrint("🔗 BackgroundDeliveryManager: EventSink attached (Flutter is listening)")
        } else {
            debugPrint("🔌 BackgroundDeliveryManager: EventSink detached")
        }
    }
    
    func configure(mode: BackgroundDeliveryMode, apiURL: URL?, headers: [String: String]) async {
        if self.mode == mode, self.apiURL == apiURL, self.headers == headers {
            debugPrint("📦 BackgroundDeliveryManager: configure skipped — unchanged")
            return
        }
        self.mode = mode
        self.apiURL = apiURL
        self.headers = headers

        UserDefaults.standard.set(mode.rawValue, forKey: "HumangoDeliveryMode")
        UserDefaults.standard.set(apiURL, forKey: "HumangoDeliveryURL")
        UserDefaults.standard.set(headers, forKey: "HumangoDeliveryHeaders")
        UserDefaults.standard.synchronize()
    }

    /// Clears all persisted background delivery configuration.
    /// Called on user logout so monitoring does not auto-restart on the next app launch.
    func clearConfiguration() {
        mode = .localStorage
        apiURL = nil
        headers = [:]
        UserDefaults.standard.removeObject(forKey: "HumangoDeliveryMode")
        UserDefaults.standard.removeObject(forKey: "HumangoDeliveryURL")
        UserDefaults.standard.removeObject(forKey: "HumangoDeliveryHeaders")
        UserDefaults.standard.synchronize()
        debugPrint("🔐 [WorkoutDelivery] Cleared background delivery configuration on logout")
    }
    
    func deliverWorkout(_ workoutJSONString: String, deviceId: String) async {
        debugPrint("📤 [WorkoutDelivery] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        debugPrint("📤 [WorkoutDelivery] Delivering workout: deviceId=\(deviceId)")
        debugPrint("📤 [WorkoutDelivery] Mode: \(mode.rawValue)")
        debugPrint("📤 [WorkoutDelivery] JSON size: \(workoutJSONString.count) chars / \(workoutJSONString.data(using: .utf8)?.count ?? 0) bytes")
        debugPrint("📤 [WorkoutDelivery] JSON preview: \(String(workoutJSONString.prefix(500)))...")
        debugPrint("📤 [WorkoutDelivery] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        switch mode {
        case .api:
            // API mode: always push to API regardless of foreground/background
            debugPrint("📤 [WorkoutDelivery] API mode — pushing workout \(deviceId) to API")
            await pushToAPI(workoutJSONString, deviceActivityId: deviceId)
            
        case .localStorage:
            // Default mode: use Flutter stream if available (foreground), otherwise store locally (background)
            if let sink = self.eventSink {
                debugPrint("📤 BackgroundDeliveryManager: Pushing workout \(deviceId) to Flutter eventSink")
                DispatchQueue.main.async {
                    sink(workoutJSONString)
                }
                debugPrint("✅ BackgroundDeliveryManager: Workout \(deviceId) delivered to Flutter stream")
            } else {
                debugPrint("⚠️ BackgroundDeliveryManager: No eventSink (background) — storing workout \(deviceId) locally")
                await storeLocally(workoutJSONString)
            }
        }
    }
    
    private func pushToAPI(_ workoutJSON: String, deviceActivityId: String) async {
        guard let url = apiURL else {
            debugPrint("⚠️ [WorkoutDelivery] API push failed: No API URL configured")
            return
        }
        guard let data = workoutJSON.data(using: .utf8) else {
            debugPrint("⚠️ [WorkoutDelivery] API push failed: Cannot encode JSON to UTF8 data")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Log API call details
        debugPrint("🌐 [WorkoutDelivery] ── API REQUEST ──────────────────────────")
        debugPrint("🌐 [WorkoutDelivery] URL: \(url.absoluteString)")
        debugPrint("🌐 [WorkoutDelivery] Method: POST")
        debugPrint("🌐 [WorkoutDelivery] Headers:")
        debugPrint("🌐 [WorkoutDelivery]   Content-Type: application/json")
        for (key, value) in headers {
            let maskedValue = key.lowercased().contains("auth") ? "\(value.prefix(10))...***" : value
            debugPrint("🌐 [WorkoutDelivery]   \(key): \(maskedValue)")
        }
        debugPrint("🌐 [WorkoutDelivery] Body size: \(data.count) bytes")
        debugPrint("🌐 [WorkoutDelivery] Body preview: \(String(workoutJSON.prefix(300)))...")
        debugPrint("🌐 [WorkoutDelivery] DeviceActivityId: \(deviceActivityId)")
        debugPrint("🌐 [WorkoutDelivery] Sending request...")
        
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: responseData, encoding: .utf8) ?? "<non-UTF8>"
            
            debugPrint("🌐 [WorkoutDelivery] ── API RESPONSE ─────────────────────────")
            debugPrint("🌐 [WorkoutDelivery] Status: \(statusCode)")
            debugPrint("🌐 [WorkoutDelivery] Response body: \(String(responseBody.prefix(500)))")
            
            if (200...299).contains(statusCode) {
                await WorkoutRecordStore.shared.markPushed(deviceActivityId: deviceActivityId)
                debugPrint("✅ [WorkoutDelivery] API push succeeded for \(deviceActivityId) (HTTP \(statusCode))")
            } else {
                debugPrint("⚠️ [WorkoutDelivery] API push failed with HTTP \(statusCode) for \(deviceActivityId)")
            }
        } catch {
            debugPrint("❌ [WorkoutDelivery] API push network error for \(deviceActivityId): \(error)")
            debugPrint("❌ [WorkoutDelivery] Error type: \(type(of: error)), description: \(error.localizedDescription)")
        }
    }
    
    private func storeLocally(_ workoutJSON: String) async {
        let key = "BackgroundWorkouts.pending"
        var existing = UserDefaults.standard.stringArray(forKey: key) ?? []
        existing.append(workoutJSON)
        UserDefaults.standard.set(existing, forKey: key)
        UserDefaults.standard.synchronize()
        debugPrint("💾 Stored workout locally. Total pending: \(existing.count)")
    }
    
    func retrieveLocalWorkouts() async -> [String] {
        let key = "BackgroundWorkouts.pending"
        let workouts = UserDefaults.standard.stringArray(forKey: key) ?? []
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.synchronize()
        return workouts
    }
}
