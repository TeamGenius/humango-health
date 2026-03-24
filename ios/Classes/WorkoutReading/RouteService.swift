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
        startBackgroundMonitoring()
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
    func startBackgroundMonitoring() {
        
        
        Task {
                do {
                    try await healthStore.enableBackgroundDelivery(for: HKSeriesType.workoutRoute(), frequency: .immediate)
                } catch {
                    debugPrint("[RouteService] enableBackgroundDelivery(workoutRoute) failed: \(error)")
                }
            }

        observer = HKObserverQuery(sampleType: HKSeriesType.workoutRoute(), predicate: nil) { [weak self] _, completion, error in
                guard let self = self else { completion(); return }
                defer { completion() }

                if let error = error {
                    debugPrint("[RouteService] workoutRoute observer error: \(error)")
                    return
                }

            Task {
                await self.fetchWorkoutRoute()
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
        healthStore.disableBackgroundDelivery(for: HKSeriesType.workoutRoute()) { _, err in
                if let err {
                    debugPrint("[RouteService] disableBackgroundDelivery(workoutRoute) error: \(err)")
                }
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
            Task { self.handleCompleteWorkout(location: []) }
            return
        }

        routeDebounceTask?.cancel()
        let workoutUUID = workout.uuid.uuidString

        routeDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: RouteService.routeUpdateWaitSeconds * 1_000_000_000)
                guard let self = self, !Task.isCancelled else { return }
                do {
                    let locationsData: [CLLocation] = try await self.buildRouteData(from: self.workoutRoutes)
                    self.handleCompleteWorkout(location: locationsData)
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
    func handleCompleteWorkout(location: [CLLocation]) {
        Task {
            do {
                let series = try await fetchAllQuantitySeriesForWorkoutOrdered(workout)

                var dictMetaData = workout.metadata ?? [String:Any]()
                dictMetaData["dataSource"] = workout.sourceRevision.source.name
                dictMetaData["iosVersion"] = ProcessInfo.processInfo.operatingSystemVersionString

                let scheduledWorkoutId = await getScheduledWorkoutId(workout)
                dictMetaData["isScheduledWorkout"] = scheduledWorkoutId != nil
                if let scheduleId = scheduledWorkoutId {
                    dictMetaData["scheduledWorkoutId"] = scheduleId
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
                await pushWorkout(finalWorkout: huWorkout)
            } catch {
                debugPrint("[RouteService] handleCompleteWorkout error: \(error)")
            }
        }
    }

    // push workout payload
    func pushWorkout(finalWorkout: HuWorkout) async {
        guard let dict = finalWorkout.toDict() else {
            debugPrint("[RouteService] pushWorkout: toDict() returned nil for \(finalWorkout.deviceActivityId)")
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            let deviceId = finalWorkout.deviceActivityId
            guard let jsonString = String(data: data, encoding: .utf8) else {
                debugPrint("[RouteService] pushWorkout: UTF-8 encoding failed for \(deviceId)")
                return
            }
            if let delegate = HumangoHealthPlugin.delegate {
                delegate.onWorkoutReady(json: jsonString, deviceId: deviceId)
            } else {
                debugPrint("[RouteService] delegate is nil — workout \(deviceId) not delivered")
            }
        } catch {
            debugPrint("[RouteService] pushWorkout JSON error for \(finalWorkout.deviceActivityId): \(error)")
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


