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

@available(iOS 17.0, *)
class RouteService {
    private let healthStore: HKHealthStore
    private let workout : HKWorkout
    private var routeAnchor: HKQueryAnchor?
    private var updateTask: Task<Void, Never>?
    private var observer: HKObserverQuery?
    private var workoutRoutes : [HKWorkoutRoute] = []
    private let defaults: UserDefaults
    private let apiHelper = ApiHelper.shared

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
        debugPrint("Read Workouts: RouteService init for workout : \(workout.uuid.uuidString)")
    }
    
    /// Expose endDate for external checks without exposing full workout
    public var workoutEndDate: Date {
        return workout.endDate
    }

    // MARK: - Mode switches
    func enterBackgroundMode() {
        stopLiveUpdates()
        startBackgroundMonitoring()
        debugPrint("Read Workouts: RouteService -> entered BACKGROUND mode")
    }

    func enterForegroundMode() {
        stopBackgroundMonitoring()
        startLiveUpdates()
        debugPrint("Read Workouts: RouteService -> entered FOREGROUND mode")
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
        Task{
            do {
                try await self.delay(milliseconds: 120000)
            } catch {
                debugPrint("Task cancelled or failed: \(error)")
            }
        }
        let pred = HKQuery.predicateForObjects(from: self.workout)
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(pred)],
            anchor: routeAnchor,
            limit: HKObjectQueryNoLimit
        )
        debugPrint("Read Workouts: RouteService: fetchWorkoutRoute :\(workout.uuid)")
        do {
            let result: HKAnchoredObjectQueryDescriptor<HKWorkoutRoute>.Result = try await desc.result(for: healthStore)
            debugPrint("Read Workouts: RouteService: fetchWorkoutRoute : result:\(result.addedSamples.count)")
            routeAnchor = result.newAnchor
            let routes = result.addedSamples
            await handleWorkoutRoutes(routes: routes)
        } catch {
            print("Read Workouts: Fetch WorkoutRoute failed: \(error)")
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
            debugPrint("Read Workouts: RouteService: starting live route stream")
            do {
                for try await update in stream {
                    self.routeAnchor = update.newAnchor
                    let routes = update.addedSamples
                    if !routes.isEmpty {
                        await self.handleWorkoutRoutes(routes: routes)
                    }
                }
            } catch {
                debugPrint("Read Workouts: RouteService: RouteService live updates error: \(error)")
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
                    debugPrint("Read Workouts: RouteService: enabled background delivery for workoutRoute (immediate)")
                } catch {
                    debugPrint("Read Workouts: RouteService: enableBackgroundDelivery(workoutRoute) failed: \(error)")
                }
            }

        observer = HKObserverQuery(sampleType: HKSeriesType.workoutRoute(), predicate: nil) { [weak self] _, completion, error in
                guard let self = self else { completion(); return }
                defer { completion() }

                if let error = error {
                    debugPrint("Read Workouts: RouteService: workoutRoute observer error: \(error)")
                    return
                }

            Task {
                debugPrint("Read Workouts: RouteService: workoutRoute observer fired (background) — fetching routes")
                await self.fetchWorkoutRoute() // fetchWorkouts will create RouteService or one-shot as needed
            }
            }

            if let q = observer {
                healthStore.execute(q)
                debugPrint("Read Workouts: RouteService: installed workoutRoute observer")
            }
    }

    func stopBackgroundMonitoring() {
        if let q = observer {
            healthStore.stop(q)
            observer = nil
            debugPrint("Read Workouts: RouteService: removed workoutRoute observer")
        }
        healthStore.disableBackgroundDelivery(for: HKSeriesType.workoutRoute()) { ok, err in
                if let err {
                    debugPrint("Read Workouts: RouteService: disableBackgroundDelivery(workoutRoute) error: \(err)")
                } else {
                    debugPrint("Read Workouts: RouteService: disableBackgroundDelivery(workoutRoute) ok: \(ok)")
                }
            }
    }

    // MARK: - Upsert routes + build route data
    func handleWorkoutRoutes(routes: [HKWorkoutRoute]) async {
        // upsert by UUID (or use sync identifier if you want to coalesce replacements)
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

        // no routes? complete with empty
        guard !workoutRoutes.isEmpty else {
            Task { self.handleCompleteWorkout(location: []) }
            return
        }

        do {
            let locationsData : [CLLocation] = try await buildRouteData(from: workoutRoutes)   // ← get all locations
            // touch lastSeen so record store knows about route updates
            await WorkoutRecordStore.shared.updateLastSeen(deviceActivityId: workout.uuid.uuidString, date: Date())
            Task { self.handleCompleteWorkout(location: locationsData) }
        } catch {
            print("Read Workouts: route read error: \(error)")
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

    // MARK: - Build HuWorkout and push
    func handleCompleteWorkout(location: [CLLocation]) {
        Task {
            do {
                // fetch quantity time series in the same order as your UI/model expects
                let series = try await fetchAllQuantitySeriesForWorkoutOrdered(workout)

                var dictMetaData = workout.metadata ?? [String:Any]()
                dictMetaData["dataSource"] = workout.sourceRevision.source.name
                // UIDevice.systemVersion is a String — no await needed
                dictMetaData["iosVersion"] = UIDevice.current.systemVersion

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
                print("Read Workouts: fetch error:", error)
            }
        }
    }

    // push workout payload (uses WorkoutRecordStore dedupe)
    func pushWorkout(finalWorkout : HuWorkout) async {
        guard let dict = finalWorkout.toDict() else { return }
        let arr = [dict]
        do {
            let data = try JSONSerialization.data(withJSONObject: arr, options: [])
            let deviceId = finalWorkout.deviceActivityId

            // Check local store (dedupe)
            let shouldPush = await WorkoutRecordStore.shared.shouldPush(deviceActivityId: deviceId, payload: data)
            if !shouldPush {
                debugPrint("Read Workouts: Skipping push — already pushed and unchanged for \(deviceId)")
                return
            }

            // Mark pending (so concurrent calls won't duplicate)
            await WorkoutRecordStore.shared.upsertRecordPending(deviceActivityId: deviceId, payload: data)

            // ensure we have url/token (synchronous properties)
            guard let url = self.apiURL, let token = self.authToken else {
                debugPrint("Read Workouts: No apiURL or authToken")
                return
            }

            // perform network post (your existing ApiHelper)
            self.apiHelper.post(url: url, body: data, accessToken: token) { response in
                debugPrint("Read Workouts: API POST:", response.status)
                if response.status == .success {
                    Task {
                        await WorkoutRecordStore.shared.markPushed(deviceActivityId: deviceId)
                    }
                } else {
                    // failure -> leave record with pushed=false so it'll be retried later
                    debugPrint("Read Workouts: Push failed for \(deviceId) -> will retry later")
                }
            }
        } catch {
            debugPrint("Read Workouts: Workout JSON error:", error)
        }
    }

    // MARK: - Cleanup
    func invalidate() {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        workoutRoutes.removeAll()
    }
}


