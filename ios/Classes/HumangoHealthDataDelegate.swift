
//
//  HumangoHealthDataDelegate.swift
//  humango_health
//
//  Dependency-inversion contract between the library and the host app.
//
//  Push-based delivery for workouts and sleep (no plugin-owned payload queues).
//  The host app provides a concrete implementation (e.g. HumangoHealthDataHandler)
//  and injects it via `HumangoHealthPlugin.delegate` after the user logs in.
//

import Foundation

/// Implement this protocol in the host app and assign the instance to
/// `HumangoHealthPlugin.delegate` to receive workout and sleep payloads ready for upload.
public protocol HumangoHealthDataDelegate: AnyObject {

    /// Called when a completed workout is ready for processing/upload.
    ///
    /// **Must be `async`**: the library `await`s this call before signalling HealthKit's
    /// `completion()` handler. If this method returns before the upload finishes
    /// (e.g. by spawning a detached `Task {}`), iOS will re-suspend the app mid-upload.
    /// The implementation must `await` the network request directly.
    /// - Parameters:
    ///   - workout: The assembled `HuWorkout` struct with all route, sample, and metadata fields populated.
    ///   - deviceId: The HealthKit workout UUID (`deviceActivityId`).
    func onWorkoutReady(workout: HuWorkout, deviceId: String) async

    /// Called when a processed sleep session payload is ready for processing/upload.
    ///
    /// **Must be `async`**: the library `await`s this call before signalling HealthKit's
    /// `completion()` handler. The implementation must `await` the network request directly.
    /// - Parameters:
    ///   - json: Serialised sleep payload JSON string (flat aggregated format).
    ///   - sessionId: Stable session identifier derived from `BED_TIME`.
    func onSleepSessionReady(json: String, sessionId: String) async

    /// Called when a health metric monitor detects new data and delivers the
    /// current-day samples (midnight → now) for a single metric type.
    ///
    /// **Payload shape** (`payload` dict keys):
    /// - `"metricType"` — `String` matching `HealthMetricType.key` (e.g. `"bodyMass"`).
    /// - `"unit"` — `String` unit label (e.g. `"kg"`, `"ms"`, `"bpm"`).
    /// - `"samples"` — `[[String: Any]]` array of individual samples (uuid, value, unit,
    ///   startDate, endDate, sourceName, sourceBundle, device?, metadata?).
    /// - `"sampleCount"` — `Int`.
    /// - `"latestSample"` — `[String: Any]?` most-recent sample or `nil` if no data today.
    /// - `"statistics"` — `[String: Double]` with keys `average`, `min`, `max`, `sum`.
    ///   All values are raw `Double` — no rounding applied.
    /// - `"fetchedFrom"` — ISO 8601 string (midnight of today, local timezone).
    /// - `"fetchedTo"` — ISO 8601 string (moment of fetch).
    ///
    /// **Must be `async`**: the library `await`s this call before signalling HealthKit's
    /// `completion()` handler for background deliveries. The implementation must `await`
    /// any network request directly — do not spawn a detached Task.
    /// - Parameters:
    ///   - payload: The assembled metric payload dictionary (see keys above).
    ///   - metricType: The `HealthMetricType.key` string identifying which metric fired.
    func onHealthMetricReady(payload: [String: Any], metricType: String) async
}

public extension HumangoHealthDataDelegate {
    func onWorkoutReady(workout: HuWorkout, deviceId: String) async {}
    func onSleepSessionReady(json: String, sessionId: String) async {}
    func onHealthMetricReady(payload: [String: Any], metricType: String) async {}
}
