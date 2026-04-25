//
//  RawWorkoutsChannel.swift
//  Runner (example app)
//
//  Queries HealthKit workouts directly — no humango_health library classes used.
//  Channel: "com.humango.example/rawWorkouts"
//  Method:  fetchRawWorkouts({ "startDate": ISO8601, "endDate": ISO8601 })
//           → [String]  (each element is a pretty-printed JSON string for one HKWorkout)
//

import Flutter
import HealthKit
import Foundation

final class RawWorkoutsChannel: NSObject, FlutterPlugin {

    private let healthStore = HKHealthStore()

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.humango.example/rawWorkouts",
            binaryMessenger: registrar.messenger()
        )
        let instance = RawWorkoutsChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - Method dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "fetchRawWorkouts" else {
            result(FlutterMethodNotImplemented)
            return
        }

        guard
            let args = call.arguments as? [String: Any],
            let startISO = args["startDate"] as? String,
            let endISO   = args["endDate"]   as? String,
            let startDate = Self.parseISO(startISO),
            let endDate   = Self.parseISO(endISO)
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "startDate and endDate (ISO8601) are required",
                details: nil
            ))
            return
        }

        Task {
            do {
                let jsons = try await self.fetchWorkouts(from: startDate, to: endDate)
                DispatchQueue.main.async { result(jsons) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "FETCH_ERROR",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    // MARK: - HealthKit fetch

    private func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [String] {
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: HKObjectQueryNoLimit
        )

        let samples = try await descriptor.result(for: healthStore)
        let workouts = samples.compactMap { $0 as? HKWorkout }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var results: [String] = []

        for workout in workouts {
            var dict: [String: Any] = [:]

            dict["uuid"]                   = workout.uuid.uuidString
            dict["workoutActivityType"]    = workout.workoutActivityType.name
            dict["workoutActivityTypeRaw"] = workout.workoutActivityType.rawValue
            dict["startDate"]              = isoFormatter.string(from: workout.startDate)
            dict["endDate"]                = isoFormatter.string(from: workout.endDate)
            dict["durationSeconds"]        = workout.duration

            if let dist = workout.totalDistance {
                dict["totalDistanceMeters"] = dist.doubleValue(for: .meter())
            }
            if let energy = workout.totalEnergyBurned {
                dict["totalEnergyBurnedKcal"] = energy.doubleValue(for: .kilocalorie())
            }
            if let strokes = workout.totalSwimmingStrokeCount {
                dict["totalSwimmingStrokeCount"] = strokes.doubleValue(for: .count())
            }

            dict["sourceName"]     = workout.sourceRevision.source.name
            dict["sourceBundleId"] = workout.sourceRevision.source.bundleIdentifier
            dict["sourceVersion"]  = workout.sourceRevision.version ?? ""

            if let device = workout.device {
                dict["device"] = [
                    "name":            device.name ?? "",
                    "model":           device.model ?? "",
                    "manufacturer":    device.manufacturer ?? "",
                    "hardwareVersion": device.hardwareVersion ?? "",
                    "softwareVersion": device.softwareVersion ?? "",
                ] as [String: Any]
            }

            if let meta = workout.metadata, !meta.isEmpty {
                var safeMeta: [String: String] = [:]
                for (key, value) in meta { safeMeta[key] = "\(value)" }
                dict["metadata"] = safeMeta
            }

            if let events = workout.workoutEvents, !events.isEmpty {
                dict["workoutEvents"] = events.map { event -> [String: Any] in
                    [
                        "type":      event.type.rawValue,
                        "startDate": isoFormatter.string(from: event.dateInterval.start),
                        "endDate":   isoFormatter.string(from: event.dateInterval.end),
                    ]
                }
                dict["workoutEventCount"] = events.count
            }

            if !workout.allStatistics.isEmpty {
                var statsDict: [String: Any] = [:]
                for (quantityType, stats) in workout.allStatistics {
                    let unit = preferredUnit(for: quantityType)
                    var s: [String: Any] = [:]
                    if let sum = stats.sumQuantity()     { s["sum"] = sum.doubleValue(for: unit) }
                    if let avg = stats.averageQuantity() { s["avg"] = avg.doubleValue(for: unit) }
                    if let min = stats.minimumQuantity() { s["min"] = min.doubleValue(for: unit) }
                    if let max = stats.maximumQuantity() { s["max"] = max.doubleValue(for: unit) }
                    statsDict[quantityType.identifier] = s
                }
                dict["statistics"] = statsDict
            }

            if let jsonData = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            ),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                results.append(jsonString)
            }
        }

        return results
    }

    // MARK: - Helpers

    private static func parseISO(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    /// Best-effort preferred unit for common quantity types used in statistics.
    private func preferredUnit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.runningSpeed.rawValue,
             HKQuantityTypeIdentifier.cyclingSpeed.rawValue:
            return HKUnit.meter().unitDivided(by: .second())
        case HKQuantityTypeIdentifier.runningPower.rawValue,
             HKQuantityTypeIdentifier.cyclingPower.rawValue:
            return .watt()
        default:
            return .count()
        }
    }
}
