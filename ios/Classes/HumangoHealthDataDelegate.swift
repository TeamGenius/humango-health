
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

    /// Called when a quantity-metric batch is ready.
    ///
    /// **Must be `async`**: same reasoning — `await` before `completion()`.
    /// - Parameters:
    ///   - json: Serialised dictionary: `metricType`, `unit`, `samples`, `sampleCount`, `fetchedAt`.
    ///   - metricType: Typed `HealthMetricType` enum value identifying the metric batch.
    ///   - fetchedAt: ISO-8601 batch timestamp; use with `metricType` for deduplication.
    func onHealthMetricSamplesReady(json: String, metricType: HealthMetricType, fetchedAt: String) async
}

public extension HumangoHealthDataDelegate {
    func onWorkoutReady(workout: HuWorkout, deviceId: String) async {}
    func onSleepSessionReady(json: String, sessionId: String) async {}
    func onHealthMetricSamplesReady(json: String, metricType: HealthMetricType, fetchedAt: String) async {}
}
