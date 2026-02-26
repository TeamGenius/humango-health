//
//  WorkoutFetcher.swift
//  Runner
//
//  Created by Vinay Vudatala on 09/10/25.
//  Updated by ChatGPT on 2025-10-09.
//  Paste-ready: uses your existing HuWorkout (must provide `toJson()`).
//

import Foundation
import HealthKit
import CoreLocation
import UIKit
import Flutter

@available(iOS 17.0, *)
final class WorkoutFetcher {

    static let shared = WorkoutFetcher()

    private let store = HKHealthStore()
    private var anchor: HKQueryAnchor?
    private var importRunning = true
    private var importCycling = true
    private var importSwimming = true
    private var unImportWorkout: [String] = []

    private init() {
        // Read user preferences if you use them; defaults to true here.
        importRunning = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportRunning)
        importCycling = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportCycling)
        importSwimming = UserDefaults.standard.bool(forKey: UserDefaultsKeys.isImportSwimming)
        rebuildUnImport()
    }

    private func rebuildUnImport() {
        unImportWorkout.removeAll()
        if !importRunning { unImportWorkout.append("Running") }
        if !importCycling { unImportWorkout.append("Cycling") }
        if !importSwimming { unImportWorkout.append("Swimming") }
    }

    // MARK: - Public fetch API

    /// One-shot fetch between `startDate` .. `effectiveEnd`.
    /// Assumes authorization is already handled externally.
    /// Returns an array of JSON strings produced by your HuWorkout.toJson().
    func fetchWorkouts(startDate: Date, effectiveEnd: Date) async throws -> [String] {
        var workouts: [HuWorkout] = []

        // Do NOT overwrite effectiveEnd (use the passed parameter)
        let initialPredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: effectiveEnd,
            options: [.strictStartDate, .strictEndDate]
        )

        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(initialPredicate)],
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        )

        do {
            let result: HKAnchoredObjectQueryDescriptor<HKWorkout>.Result = try await desc.result(for: store)
            debugPrint("WorkoutFetcher: anchored result — addedSamples.count = \(result.addedSamples.count)")
            anchor = result.newAnchor

            for w in result.addedSamples {
                debugPrint("WorkoutFetcher: read workout: \(w.uuid.uuidString) type:\(w.workoutActivityType.name)")
                if unImportWorkout.contains(w.workoutActivityType.name) {
                    debugPrint("WorkoutFetcher: skipping due to prefs: \(w.workoutActivityType.name)")
                    continue
                }
                do {
                    if let hu = try await handleWorkouts(workout: w) {
                        workouts.append(hu)
                    }
                } catch {
                    debugPrint("WorkoutFetcher: handleWorkouts failed for \(w.uuid.uuidString): \(error)")
                }
            }
        } catch {
            debugPrint("WorkoutFetcher: fetch anchored query failed: \(error)")
            throw error
        }

        // Convert to JSON strings using your HuWorkout.toJson() implementation (returns Data?)
        var workoutsJson: [String] = []
      
        for workout in workouts {
            guard let dict = workout.toDict() else { continue }
            let arr = [dict]
            let deviceId = workout.deviceActivityId
            let data = try JSONSerialization.data(withJSONObject: arr, options: [])
            
            // Check local store (dedupe)
            let shouldPush = await WorkoutRecordStore.shared.shouldPush(deviceActivityId: deviceId, payload: data)
            if !shouldPush {
                debugPrint("Read Workouts: Skipping push — already pushed and unchanged for \(deviceId)")
                continue
            }
            // Mark pending (so concurrent calls won't duplicate)
            await WorkoutRecordStore.shared.upsertRecordPending(deviceActivityId: deviceId, payload: data)

            let jsonOrNil = workout.toJson()
            if jsonOrNil != nil {
                // the channel doesn't encode as UTF8, so we do it here
                let jsonString = String(data: jsonOrNil!, encoding: .utf8) ?? ""
                debugPrint("jsonString",jsonString)
                workoutsJson.append(jsonString)
            }
        }
        return workoutsJson
    }

    // MARK: - Route & series helpers

    func fetchWorkoutRoute(workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        var routeAnchor: HKQueryAnchor?
        let pred = HKQuery.predicateForObjects(from: workout)
        let desc = HKAnchoredObjectQueryDescriptor(predicates: [.workoutRoute(pred)], anchor: routeAnchor, limit: HKObjectQueryNoLimit)
        let res: HKAnchoredObjectQueryDescriptor<HKWorkoutRoute>.Result = try await desc.result(for: store)
        return res.addedSamples
    }

    func fetchAllQuantitySeriesForWorkoutOrdered(_ workout: HKWorkout, store: HKHealthStore) async throws -> [[HKQuantitySample]] {
        let ids: [HKQuantityTypeIdentifier] = [
            HKQuantityTypeIdentifier.heartRate,
            HKQuantityTypeIdentifier.stepCount,
            HKQuantityTypeIdentifier.distanceCycling,
            HKQuantityTypeIdentifier.swimmingStrokeCount,
            HKQuantityTypeIdentifier.distanceSwimming,
            HKQuantityTypeIdentifier.vo2Max,
            HKQuantityTypeIdentifier.distanceWalkingRunning,
            HKQuantityTypeIdentifier.activeEnergyBurned,
            HKQuantityTypeIdentifier.bodyMass,
            HKQuantityTypeIdentifier.height,
            HKQuantityTypeIdentifier.restingHeartRate,
            HKQuantityTypeIdentifier.heartRateVariabilitySDNN,
            HKQuantityTypeIdentifier.bodyMassIndex,
            // running-related (iOS 16+)
            HKQuantityTypeIdentifier.runningGroundContactTime,
            HKQuantityTypeIdentifier.runningPower,
            HKQuantityTypeIdentifier.runningSpeed,
            HKQuantityTypeIdentifier.runningStrideLength,
            HKQuantityTypeIdentifier.runningVerticalOscillation,
            // cycling (iOS 17+)
            HKQuantityTypeIdentifier.cyclingCadence,
            HKQuantityTypeIdentifier.cyclingPower,
        ]

      

        return try await withThrowingTaskGroup(of: (Int, [HKQuantitySample]).self) { group in
            for (idx, id) in ids.enumerated() {
                group.addTask {
                    guard let qType = HKObjectType.quantityType(forIdentifier: id) else {
                        return (idx, [])
                    }
                    let pred = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictEndDate)
                    let descriptor = HKSampleQueryDescriptor(
                        predicates: [.sample(type: qType, predicate: pred)],
                        sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
                        limit: HKObjectQueryNoLimit
                    )
                    let results = try await descriptor.result(for: store)
                    let samples = results.compactMap { $0 as? HKQuantitySample }
                    return (idx, samples)
                }
            }

            var temp = Array(repeating: [HKQuantitySample](), count: ids.count)
            for try await (idx, samples) in group {
                if idx >= 0 && idx < temp.count {
                    temp[idx] = samples
                }
            }
            return temp
        }
    }

    private func buildRouteData(from routes: [HKWorkoutRoute]) async throws -> [CLLocation] {
        var allPoints: [CLLocation] = []
        for route in routes {
            let seq = HKWorkoutRouteQueryDescriptor(route).results(for: store)
            for try await loc in seq {
                allPoints.append(loc)
            }
        }
        return allPoints
    }

    // MARK: - Build HuWorkout (uses your existing HuWorkout type)

    func handleWorkouts(workout: HKWorkout) async throws -> HuWorkout? {
        guard workout.endDate > workout.startDate else {
            debugPrint("WorkoutFetcher: skipping incomplete workout: \(workout.uuid.uuidString)")
            return nil
        }

        let series = try await fetchAllQuantitySeriesForWorkoutOrdered(workout, store: store)
        let routes = try await fetchWorkoutRoute(workout: workout)
        let locations = try await buildRouteData(from: routes)

        // Add additional metadata
        var dictMetaData = workout.metadata ?? [:]
        dictMetaData["dataSource"] = workout.sourceRevision.source.name
        dictMetaData["iosVersion"] = UIDevice.current.systemVersion

        // Construct your HuWorkout. Adjust initializer to match your HuWorkout signature.
        // Example assumes a constructor similar to what you previously used:
        let huWorkout = HuWorkout(
            distance: workout.totalDistance,
            duration: workout.duration,
            sport: workout.workoutActivityType,
            start_time: workout.startDate,
            routeData: HuRouteData(samples: series, locations: locations),
            deviceActivityId: workout.uuid.uuidString,
            statistics: workout.allStatistics,
            events: workout.workoutEvents,
            workoutActivities: workout.workoutActivities,
            metadata: dictMetaData
        )

        return huWorkout
    }
}




