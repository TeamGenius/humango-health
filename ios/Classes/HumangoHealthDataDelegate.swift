
//
//  HumangoHealthDataDelegate.swift
//  humango_health
//
//  Dependency-inversion contract between the library and the host app.
//
//  The library fires these callbacks instead of writing to UserDefaults queues.
//  The host app provides a concrete implementation (e.g. HumangoHealthDataHandler)
//  and injects it via `HumangoHealthPlugin.delegate` after the user logs in.
//

import Foundation

/// Implement this protocol in the host app and assign the instance to
/// `HumangoHealthPlugin.delegate` to receive health data ready for upload.
public protocol HumangoHealthDataDelegate: AnyObject {

    /// Called when a completed workout is ready for processing/upload.
    /// - Parameters:
    ///   - json: Serialised `HuWorkout` JSON string.
    ///   - deviceId: The HealthKit workout UUID (`deviceActivityId`).
    func onWorkoutReady(json: String, deviceId: String)

    /// Called when a processed sleep session payload is ready for processing/upload.
    /// - Parameters:
    ///   - json: Serialised sleep payload JSON string (flat aggregated format).
    ///   - sessionId: Stable session identifier derived from `BED_TIME`.
    func onSleepSessionReady(json: String, sessionId: String)
}
