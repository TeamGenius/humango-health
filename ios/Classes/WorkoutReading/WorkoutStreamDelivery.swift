import Foundation
import Flutter

/// Delivers completed workout JSON to Flutter's `workoutStream` when an [FlutterEventSink] is attached;
/// otherwise appends to a UserDefaults queue for later retrieval (same keys as before).
/// Workout background delivery does **not** perform HTTP — the host app uploads via Dart or its own native code.
@available(iOS 13.0, *)
final class WorkoutStreamDelivery {
    static let shared = WorkoutStreamDelivery()

    private static let pendingKey = "BackgroundWorkouts.pending"
    private static let legacyModeKey = "HumangoDeliveryMode"
    private static let legacyUrlKey = "HumangoDeliveryURL"
    private static let legacyHeadersKey = "HumangoDeliveryHeaders"

    private var eventSink: FlutterEventSink?

    private init() {}

    func attachEventSink(_ sink: FlutterEventSink?) {
        eventSink = sink
        if sink != nil {
            debugPrint("🔗 WorkoutStreamDelivery: EventSink attached")
        } else {
            debugPrint("🔌 WorkoutStreamDelivery: EventSink detached")
        }
    }

    func clearConfiguration() {
        clearLegacyApiKeys()
        UserDefaults.standard.synchronize()
        eventSink = nil
        debugPrint("🔐 WorkoutStreamDelivery: cleared configuration on logout")
    }

    private func clearLegacyApiKeys() {
        UserDefaults.standard.removeObject(forKey: Self.legacyModeKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyUrlKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyHeadersKey)
    }

    func deliverWorkout(_ workoutJSONString: String, deviceId: String) async {
        if let sink = eventSink {
            debugPrint("📤 WorkoutStreamDelivery: delivering \(deviceId) to Flutter stream")
            DispatchQueue.main.async {
                sink(workoutJSONString)
            }
        } else {
            debugPrint("⚠️ WorkoutStreamDelivery: no EventSink — storing \(deviceId) in pending queue")
            await storePending(workoutJSONString)
        }
    }

    private func storePending(_ workoutJSON: String) async {
        var existing: [String] = UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
        existing.append(workoutJSON)
        UserDefaults.standard.set(existing, forKey: Self.pendingKey)
        UserDefaults.standard.synchronize()
        debugPrint("💾 WorkoutStreamDelivery: pending count=\(existing.count)")
    }

    func retrieveLocalWorkouts() async -> [String] {
        let workouts = UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        UserDefaults.standard.synchronize()
        return workouts
    }
}
