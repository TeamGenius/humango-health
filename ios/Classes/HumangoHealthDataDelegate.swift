
//
//  HumangoHealthDataDelegate.swift
//  humango_health
//
//  Dependency-inversion contract between the library and the host app.
//
//  Push-based delivery for workouts, sleep, and quantity metrics (no plugin-owned payload queues).
//  The host app provides a concrete implementation (e.g. HumangoHealthDataHandler)
//  and injects it via `HumangoHealthPlugin.delegate` after the user logs in.
//

import Foundation

/// Implement this protocol in the host app and assign the instance to
/// `HumangoHealthPlugin.delegate` to receive health data ready for upload.
public protocol HumangoHealthDataDelegate: AnyObject {

    /// Called when a completed workout is ready for processing/upload.
    /// - Parameters:
    ///   - workout: The assembled `HuWorkout` struct with all route, sample, and metadata fields populated.
    ///   - deviceId: The HealthKit workout UUID (`deviceActivityId`).
    func onWorkoutReady(workout: HuWorkout, deviceId: String)

    /// Called when a processed sleep session payload is ready for processing/upload.
    /// - Parameters:
    ///   - json: Serialised sleep payload JSON string (flat aggregated format).
    ///   - sessionId: Stable session identifier derived from `BED_TIME`.
    func onSleepSessionReady(json: String, sessionId: String)

    /// Called when a quantity-metric batch is ready (same shape as each `hrv_updates` EventChannel event).
    /// Fires while metric monitoring is enabled: **HRV, heart rate, resting HR, body fat, weight, height**
    /// (see `HRVObserverManager` / `startHRVMonitoring` on the Dart side).
    /// - Parameters:
    ///   - json: Serialised dictionary: `metricType`, `unit`, `samples`, `sampleCount`, `fetchedAt`.
    ///   - metricType: Same value as inside `json` (e.g. `heartRate`, `restingHeartRate`).
    ///   - fetchedAt: ISO-8601 batch timestamp; use with `metricType` for deduplication.
    func onHealthMetricSamplesReady(json: String, metricType: String, fetchedAt: String)
}

public extension HumangoHealthDataDelegate {
    func onWorkoutReady(workout: HuWorkout, deviceId: String) {}
    func onSleepSessionReady(json: String, sessionId: String) {}
    func onHealthMetricSamplesReady(json: String, metricType: String, fetchedAt: String) {}
}
