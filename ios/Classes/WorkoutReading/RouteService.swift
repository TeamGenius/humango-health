//
//  RouteService.swift
//  Runner
//
//  Created by Vinay Vudatala on 27/09/25.
//
//

import Foundation
import HealthKit
import CoreLocation
import WorkoutKit

@available(iOS 17.0, *)
class RouteService {
    private let healthStore: HKHealthStore
    private let workout : HKWorkout
    private var routeAnchor: HKQueryAnchor?
    private var updateTask: Task<Void, Never>?
    private var observer: HKObserverQuery?
    private var workoutRoutes : [HKWorkoutRoute] = []
    private let defaults: UserDefaults

    /// Debounce task: waits 3 minutes after the last route update before pushing the workout.
    /// If new route data arrives within the window, this task is cancelled and restarted.
    private var routeDebounceTask: Task<Void, Never>?
    /// Duration (in seconds) to wait for additional route updates before finalizing the workout push.
    private static let routeUpdateWaitSeconds: UInt64 = 1 * 60  // 1 minute

    private var apiURL: URL? {
        guard
            let urlString = defaults.string(forKey: UserDefaultsKeys.apiURL),
            let url = URL(string: urlString)
        else { return nil }
        return url
    }

    private var authToken: String? {
        defaults.string(forKey: UserDefaultsKeys.token)
    }

    init(
        workout: HKWorkout,
        defaults: UserDefaults = .standard,
        healthStore: HKHealthStore = SharedHealthKitStore.shared
    ) {
        self.defaults = defaults
        self.healthStore = healthStore
        self.workout = workout

    }
    
    /// Expose endDate for external checks without exposing full workout
    public var workoutEndDate: Date {
        return workout.endDate
    }

    // MARK: - Mode switches
    func enterBackgroundMode() {
        stopLiveUpdates()
        Task { await startBackgroundMonitoring() }
    }

    func enterForegroundMode() {
        stopBackgroundMonitoring()
        startLiveUpdates()
    }

    // MARK: - Fetch all quantity series (ordered) for a workout
    // Restored from your repository: collects many quantity series in parallel and returns in the original order.
    @available(iOS 17.0, *)
    func fetchAllQuantitySeriesForWorkoutOrdered(_ workout: HKWorkout) async throws -> [[HKQuantitySample]] {
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

        let hk = healthStore
        return try await withThrowingTaskGroup(of: (Int, [HKQuantitySample]).self) { group in
            for (idx, id) in ids.enumerated() {
                group.addTask {
                    guard let qType = HKObjectType.quantityType(forIdentifier: id) else {
                        return (idx, [])
                    }

                    // predicate bounded to workout start/end
                    let pred = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictEndDate)

                    // Use HKSampleQueryDescriptor so we keep descriptor-style fetching (same API style as the rest)
                    let descriptor = HKSampleQueryDescriptor(
                        predicates: [.sample(type: qType, predicate: pred)],
                        sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
                        limit: HKObjectQueryNoLimit
                    )

                    let results = try await descriptor.result(for: hk)
                    // filter/cast to HKQuantitySample
                    let samples = results.compactMap { $0 as? HKQuantitySample }
                    return (idx, samples)
                }
            }

            var temp = Array(repeating: [HKQuantitySample](), count: ids.count)
            for try await (idx, samples) in group {
                temp[idx] = samples
            }
            return temp
        }
    }

    // MARK: - Descriptor-based fetch of today's / delta route samples (uses your HKAnchoredObjectQueryDescriptor)
    func fetchWorkoutRoute() async {
        let pred = HKQuery.predicateForObjects(from: self.workout)
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(pred)],
            anchor: routeAnchor,
            limit: HKObjectQueryNoLimit
        )
        do {
            let result: HKAnchoredObjectQueryDescriptor<HKWorkoutRoute>.Result = try await desc.result(for: healthStore)
            routeAnchor = result.newAnchor
            await handleWorkoutRoutes(routes: result.addedSamples)
        } catch {
            print("[RouteService] fetchWorkoutRoute failed: \(error)")
        }
    }

    // MARK: - Live stream while app is open (descriptor streaming)
    func startLiveUpdates() {
        let livePred = HKQuery.predicateForObjects(from: workout)
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(livePred)],
            anchor: routeAnchor
        )
        let stream = desc.results(for: healthStore)

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await update in stream {
                    self.routeAnchor = update.newAnchor
                    let routes = update.addedSamples
                    if !routes.isEmpty {
                        await self.handleWorkoutRoutes(routes: routes)
                    }
                }
            } catch {
                debugPrint("[RouteService] live updates error: \(error)")
            }
        }
    }

    func stopLiveUpdates() {
        updateTask?.cancel()
        updateTask = nil
    }

    // MARK: - Background observer/wake-ups
    func startBackgroundMonitoring() async {
        do {
            try await healthStore.enableBackgroundDelivery(for: HKSeriesType.workoutRoute(), frequency: .immediate)
        } catch {
            debugPrint("[RouteService] enableBackgroundDelivery(workoutRoute) failed: \(error)")
        }

        observer = HKObserverQuery(sampleType: HKSeriesType.workoutRoute(), predicate: nil) { [weak self] _, completion, error in
                guard let self = self else { completion(); return }
                // NOTE: Do NOT use `defer { completion() }` here.
                // completion() must be called AFTER all async work (fetch → build → push)
                // finishes so iOS keeps the app alive for the full pipeline.
                // Calling it early via defer lets iOS re-suspend the app before the
                // route data is fetched, built, and delivered to the delegate.

                if let error = error {
                    debugPrint("[RouteService] workoutRoute observer error: \(error)")
                    completion()
                    return
                }

            Task {
                await self.fetchWorkoutRoute()
                // Signal HealthKit only after the full fetch → build → push chain completes.
                completion()
            }
            }

            if let q = observer {
                healthStore.execute(q)
            }
    }

    func stopBackgroundMonitoring() {
        if let q = observer {
            healthStore.stop(q)
            observer = nil
        }
    }

    // MARK: - Upsert routes + debounced build/push
    /// Upserts incoming route samples and starts (or restarts) a 3-minute debounce timer.
    /// If no new route data arrives within 3 minutes the workout is finalized and pushed.
    /// Any earlier pending push is discarded when new route data resets the timer.
    func handleWorkoutRoutes(routes: [HKWorkoutRoute]) async {
        // upsert by UUID
        var indexByUUID: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: workoutRoutes.enumerated().map { ($1.uuid, $0) }
        )
        for route in routes {
            if let i = indexByUUID[route.uuid] {
                workoutRoutes[i] = route
            } else {
                indexByUUID[route.uuid] = workoutRoutes.count
                workoutRoutes.append(route)
            }
        }

        guard !workoutRoutes.isEmpty else {
            routeDebounceTask?.cancel()
            routeDebounceTask = nil
            if AppLifecycleManager.shared.isInForeground {
                // Foreground: fire-and-forget so fetchWorkoutRoute() returns promptly
                // and startLiveUpdates() is not blocked waiting for the full delegate
                // pipeline (which may include long waits in resolveScheduledWorkoutId).
                // Mirrors the non-empty-routes debounce Task pattern below.
                Task { [weak self] in await self?.handleCompleteWorkout(location: []) }
            } else {
                // Background: must await to keep the app alive until HealthKit's
                // completion() is signalled after the full push pipeline finishes.
                await handleCompleteWorkout(location: [])
            }
            return
        }

        routeDebounceTask?.cancel()
        let workoutUUID = workout.uuid.uuidString

        // In background mode, skip the debounce entirely.
        // iOS background execution is ~30 s after the HealthKit completion signal;
        // a 60-second wait means the push never happens in background.
        // Deduplication in WorkoutRecordStore prevents duplicate pushes when the
        // observer fires again with the same route data.
        if !AppLifecycleManager.shared.isInForeground {
            do {
                let locationsData: [CLLocation] = try await buildRouteData(from: workoutRoutes)
                await handleCompleteWorkout(location: locationsData)
            } catch {
                debugPrint("[RouteService] background route build error (\(workoutUUID)): \(error)")
            }
            return
        }

        // Foreground: debounce to coalesce multiple rapid route updates.
        routeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: RouteService.routeUpdateWaitSeconds * 1_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                do {
                    let locationsData: [CLLocation] = try await self.buildRouteData(from: self.workoutRoutes)
                    await self.handleCompleteWorkout(location: locationsData)
                } catch {
                    debugPrint("[RouteService] route build error after debounce (\(workoutUUID)): \(error)")
                }
            } catch {
                // CancellationError — new route data arrived and reset the timer; expected
            }
        }
    }

    // Reads locations from ALL route samples, merges, and returns [CLLocation]
    private func buildRouteData(from routes: [HKWorkoutRoute]) async throws -> [CLLocation] {
        var allPoints: [CLLocation] = []

        // sequential is simplest; you can parallelize with TaskGroup later if needed
        for route in routes {
            let seq = HKWorkoutRouteQueryDescriptor(route).results(for: healthStore)
            for try await loc in seq {
                allPoints.append(loc)
            }
        }

        return allPoints
    }
    
    func delay(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
    
    // MARK: - Scheduled Workout Detection
    
    /// Checks if a workout was created from a scheduled WorkoutKit workout
    /// Returns the schedule_id if matched, nil otherwise
    private func getScheduledWorkoutId(_ workout: HKWorkout) async -> String? {
        return ScheduledWorkoutStore.shared.findMatchingScheduledWorkout(
            startDate: workout.startDate,
            activityType: workout.workoutActivityType
        )
    }

    // MARK: - Build HuWorkout and push
    // Made `async` so callers can await the full fetch → build → push pipeline.
    // This is required for the background path where HealthKit's completion() must
    // not be called until the delegate has been notified (onWorkoutReady).
    func handleCompleteWorkout(location: [CLLocation]) async {
        do {
            let series = try await fetchAllQuantitySeriesForWorkoutOrdered(workout)

            var dictMetaData = workout.metadata ?? [String:Any]()
            dictMetaData["dataSource"] = workout.sourceRevision.source.name
            dictMetaData["iosVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
            // Stamp isUserEnteredWorkout — backend uses this to decide how to handle the workout.
            // HKWasUserEntered is stored as an ObjC BOOL boxed in NSNumber; in Swift's [String:Any]
            // it may surface as NSNumber or Bool depending on the runtime path, so try both.
            let _hkUserEntered = workout.metadata?[HKMetadataKeyWasUserEntered]
            let isUserEntered = (_hkUserEntered as? NSNumber)?.boolValue
                             ?? (_hkUserEntered as? Bool)
                             ?? false
            dictMetaData["isUserEnteredWorkout"] = isUserEntered

            // Lightweight date+type matching only — workoutPlan resolution is deferred
            // to the client via resolveScheduledWorkoutId(workoutUUID:) to avoid hangs.
            let scheduledWorkoutId = await getScheduledWorkoutId(workout)
            dictMetaData["isScheduledWorkout"] = scheduledWorkoutId != nil
            if let scheduleId = scheduledWorkoutId {
                dictMetaData["scheduledWorkoutId"] = scheduleId
                debugPrint("[RouteService] matched scheduleId: \(scheduleId) via date+type")
            } else {
                debugPrint("[RouteService] scheduledWorkoutId: nil — not a scheduled workout")
            }

            let huWorkout = HuWorkout(
                distance: workout.totalDistance,
                duration: workout.duration,
                sport: workout.workoutActivityType,
                start_time: workout.startDate,
                routeData: HuRouteData(samples: series, locations: location),
                deviceActivityId: workout.uuid.uuidString,
                statistics: workout.allStatistics,
                events: workout.workoutEvents,
                workoutActivities: workout.workoutActivities,
                metadata: dictMetaData
            )

            let payloadString: String
            if let jsonData = huWorkout.toJson(), let jsonString = String(data: jsonData, encoding: .utf8) {
                payloadString = jsonString
            } else {
                payloadString = "{}"
            }

            await pushWorkout(finalWorkout: huWorkout)
        } catch {
            debugPrint("[RouteService] handleCompleteWorkout error: \(error)")
        }
    }

    // push workout payload
    // `await` the delegate so the upload completes before completion() is signalled
    // to HealthKit. Without `await` iOS re-suspends the app before the network
    // request from the host app's handler finishes.
    func pushWorkout(finalWorkout: HuWorkout) async {
        let deviceId = finalWorkout.deviceActivityId
        let payloadString: String
        if let jsonData = finalWorkout.toJson(), let jsonString = String(data: jsonData, encoding: .utf8) {
            payloadString = jsonString
        } else {
            payloadString = "{}"
        }

        if let delegate = HumangoHealthPlugin.delegate {
            await delegate.onWorkoutReady(workout: finalWorkout, deviceId: deviceId)
        } else {
            debugPrint("[RouteService] delegate is nil — workout \(deviceId) not delivered")
        }
    }

    // MARK: - Cleanup
    func invalidate() {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        routeDebounceTask?.cancel()
        routeDebounceTask = nil
        workoutRoutes.removeAll()
    }
}


