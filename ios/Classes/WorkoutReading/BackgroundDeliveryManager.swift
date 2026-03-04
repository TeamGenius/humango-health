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
    
    private var mode: BackgroundDeliveryMode = .localStorage
    private var apiURL: URL?
    private var headers: [String: String] = [:]
    
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
        self.mode = mode
        self.apiURL = apiURL
        self.headers = headers
        
        UserDefaults.standard.set(mode.rawValue, forKey: "HumangoDeliveryMode")
        UserDefaults.standard.set(apiURL, forKey: "HumangoDeliveryURL")
        UserDefaults.standard.set(headers, forKey: "HumangoDeliveryHeaders")
        UserDefaults.standard.synchronize()
    }
    
    func deliverWorkout(_ workoutJSONString: String, deviceId: String) async {
        switch mode {
        case .api:
            // API mode: always push to API regardless of foreground/background
            debugPrint("📤 BackgroundDeliveryManager: API mode — pushing workout \(deviceId) to API")
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
            debugPrint("⚠️ Background API Delivery failed: No API URL configured")
            return
        }
        guard let data = workoutJSON.data(using: .utf8) else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                await WorkoutRecordStore.shared.markPushed(deviceActivityId: deviceActivityId)
                debugPrint("✅ Background API push succeeded for \(deviceActivityId)")
            } else {
                debugPrint("⚠️ Background API Response failed: \(response)")
            }
        } catch {
            debugPrint("❌ Background API Delivery push failed: \(error)")
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
