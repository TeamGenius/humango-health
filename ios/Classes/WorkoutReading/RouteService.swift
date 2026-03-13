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
    private let store : HKHealthStore
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

    init(store : HKHealthStore, workout: HKWorkout, defaults: UserDefaults = .standard){
        self.defaults = defaults
        self.store = store
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
    func fetchAllQuantitySeriesForWorkoutOrdered(
        _ workout: HKWorkout,
        store: HKHealthStore
    ) async throws -> [[HKQuantitySample]] {
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

                    // predicate bounded to workout start/end
                    let pred = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictEndDate)

                    // Use HKSampleQueryDescriptor so we keep descriptor-style fetching (same API style as the rest)
                    let descriptor = HKSampleQueryDescriptor(
                        predicates: [.sample(type: qType, predicate: pred)],
                        sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
                        limit: HKObjectQueryNoLimit
                    )

                    let results = try await descriptor.result(for: store)
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
        debugPrint("🔍 RouteService: fetchWorkoutRoute starting for \(workout.uuid.uuidString)")
        let pred = HKQuery.predicateForObjects(from: self.workout)
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(pred)],
            anchor: routeAnchor,
            limit: HKObjectQueryNoLimit
        )
        debugPrint("Read Workouts: RouteService: fetchWorkoutRoute :\(workout.uuid)")
        do {
            let result: HKAnchoredObjectQueryDescriptor<HKWorkoutRoute>.Result = try await desc.result(for: store)
            debugPrint("Read Workouts: RouteService: fetchWorkoutRoute : result:\(result.addedSamples.count)")
            routeAnchor = result.newAnchor
            let routes = result.addedSamples
            debugPrint("🔄 RouteService: About to call handleWorkoutRoutes with \(routes.count) route(s)")
            await handleWorkoutRoutes(routes: routes)
            debugPrint("✅ RouteService: handleWorkoutRoutes completed")
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
        let stream = desc.results(for: store)

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
                    try await store.enableBackgroundDelivery(for: HKSeriesType.workoutRoute(), frequency: .immediate)
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
                store.execute(q)
                debugPrint("Read Workouts: RouteService: installed workoutRoute observer")
            }
    }

    func stopBackgroundMonitoring() {
        if let q = observer {
            store.stop(q)
            observer = nil
            debugPrint("Read Workouts: RouteService: removed workoutRoute observer")
        }
        store.disableBackgroundDelivery(for: HKSeriesType.workoutRoute()) { ok, err in
                if let err {
                    debugPrint("Read Workouts: RouteService: disableBackgroundDelivery(workoutRoute) error: \(err)")
                } else {
                    debugPrint("Read Workouts: RouteService: disableBackgroundDelivery(workoutRoute) ok: \(ok)")
                }
            }
    }

    // MARK: - Upsert routes + debounced build/push
    /// Upserts incoming route samples and starts (or restarts) a 3-minute debounce timer.
    /// If no new route data arrives within 3 minutes the workout is finalized and pushed.
    /// Any earlier pending push is discarded when new route data resets the timer.
    func handleWorkoutRoutes(routes: [HKWorkoutRoute]) async {
        debugPrint("📥 RouteService: handleWorkoutRoutes called with \(routes.count) route(s), current workoutRoutes: \(workoutRoutes.count)")
        
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

        debugPrint("🗺️ RouteService: After upsert, workoutRoutes.count = \(workoutRoutes.count)")
        
        // no routes? complete with empty immediately (nothing to wait for)
        guard !workoutRoutes.isEmpty else {
            debugPrint("⚠️ RouteService: No routes available, calling handleCompleteWorkout with empty location")
            routeDebounceTask?.cancel()
            routeDebounceTask = nil
            Task { self.handleCompleteWorkout(location: []) }
            return
        }

        // Cancel any previously pending debounce — we received fresh route data,
        // so the earlier workout object is discarded in favor of the updated one.
        routeDebounceTask?.cancel()
        debugPrint("⏱️ RouteService: (Re)starting 3-minute route-update debounce timer for \(workout.uuid.uuidString)")

        let workoutUUID = workout.uuid.uuidString

        routeDebounceTask = Task { [weak self] in
            do {
                // Wait 3 minutes for additional route updates
                try await Task.sleep(nanoseconds: RouteService.routeUpdateWaitSeconds * 1_000_000_000)

                // If we reach here the timer expired without cancellation → finalize
                guard let self = self else { return }
                guard !Task.isCancelled else { return }

                debugPrint("✅ RouteService: 3-minute debounce timer expired for \(workoutUUID) — finalizing with \(self.workoutRoutes.count) route(s)")

                do {
                    debugPrint("🏗️ RouteService: Building route data from \(self.workoutRoutes.count) route(s)")
                    let locationsData: [CLLocation] = try await self.buildRouteData(from: self.workoutRoutes)
                    debugPrint("📍 RouteService: Built \(locationsData.count) location points")
                    // touch lastSeen so record store knows about route updates
                    await WorkoutRecordStore.shared.updateLastSeen(deviceActivityId: workoutUUID, date: Date())
                    self.handleCompleteWorkout(location: locationsData)
                } catch {
                    debugPrint("❌ RouteService: route build error after debounce: \(error)")
                }
            } catch {
                // Task.sleep throws CancellationError when the task is cancelled
                // (i.e. new route data arrived and reset the timer) — this is expected.
                debugPrint("🔄 RouteService: Debounce timer cancelled for \(workoutUUID) — newer route data arrived, previous workout object discarded")
            }
        }
    }

    // Reads locations from ALL route samples, merges, and returns [CLLocation]
    private func buildRouteData(from routes: [HKWorkoutRoute]) async throws -> [CLLocation] {
        var allPoints: [CLLocation] = []

        // sequential is simplest; you can parallelize with TaskGroup later if needed
        for route in routes {
            let seq = HKWorkoutRouteQueryDescriptor(route).results(for: store)
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
        debugPrint("🔎 RouteService: getScheduledWorkoutId called for \(workout.uuid.uuidString)")
        
        // Use date/type matching to find scheduled workouts
        debugPrint("📅 RouteService: Using date/type matching for scheduled workout detection...")
        let scheduledWorkoutId = ScheduledWorkoutStore.shared.findMatchingScheduledWorkout(
            startDate: workout.startDate,
            activityType: workout.workoutActivityType
        )
        
        // Additional metadata checks
        let bundleId = workout.sourceRevision.source.bundleIdentifier
        let isWorkoutApp = bundleId == "com.apple.Workout"
        
        debugPrint("🔍 Scheduled workout check for \(workout.uuid.uuidString):")
        debugPrint("   - Bundle ID: \(bundleId), isWorkoutApp: \(isWorkoutApp)")
        debugPrint("   - Start date: \(workout.startDate)")
        debugPrint("   - Activity type: \(workout.workoutActivityType.name)")
        if let scheduleId = scheduledWorkoutId {
            debugPrint("   - ✅ Matched to scheduled workout ID: \(scheduleId)")
        } else {
            debugPrint("   - ❌ No matching scheduled workout found")
        }
        
        return scheduledWorkoutId
    }

    // MARK: - Build HuWorkout and push
    func handleCompleteWorkout(location: [CLLocation]) {
        debugPrint("🏁 RouteService: handleCompleteWorkout called with \(location.count) locations for \(workout.uuid.uuidString)")
        Task {
            do {
                debugPrint("📊 RouteService: Fetching quantity series...")
                // fetch quantity time series in the same order as your UI/model expects
                let series = try await fetchAllQuantitySeriesForWorkoutOrdered(workout, store: store)
                let totalSamples = series.reduce(0) { $0 + $1.count }
                debugPrint("✅ RouteService: Fetched \(totalSamples) quantity samples across \(series.count) types")

                debugPrint("🔧 RouteService: Setting up metadata...")
                var dictMetaData = workout.metadata ?? [String:Any]()
                dictMetaData["dataSource"] = workout.sourceRevision.source.name
                dictMetaData["iosVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
                debugPrint("✅ RouteService: Metadata initialized")
                
                // Check if this workout was scheduled via WorkoutKit and get its ID
                debugPrint("🔍 RouteService: Checking if workout is scheduled...")
                let scheduledWorkoutId = await getScheduledWorkoutId(workout)
                debugPrint("✅ RouteService: Scheduled workout check complete, ID: \(scheduledWorkoutId ?? "nil")")
                let isScheduledWorkout = scheduledWorkoutId != nil
                
                dictMetaData["isScheduledWorkout"] = isScheduledWorkout
                if let scheduleId = scheduledWorkoutId {
                    dictMetaData["scheduledWorkoutId"] = scheduleId
                    debugPrint("🎯 RouteService: This is scheduled workout with ID: \(scheduleId)")
                }
                
                debugPrint("📋 RouteService: Workout source: \(workout.sourceRevision.source.name)")
                debugPrint("📋 RouteService: Workout bundleIdentifier: \(workout.sourceRevision.source.bundleIdentifier)")
                debugPrint("🎯 RouteService: Is scheduled workout: \(isScheduledWorkout)")

                debugPrint("🏗️ RouteService: Creating HuWorkout object...")
                debugPrint("   - distance: \(workout.totalDistance?.doubleValue(for: .meter()) ?? 0)m")
                debugPrint("   - duration: \(workout.duration)s")
                debugPrint("   - locations: \(location.count)")
                debugPrint("   - samples across \(series.count) types")
                
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
                debugPrint("✅ RouteService: HuWorkout created successfully")

                debugPrint("📤 RouteService: Calling pushWorkout...")
                await pushWorkout(finalWorkout: huWorkout)
                debugPrint("✅ RouteService: pushWorkout completed")
            } catch {
                debugPrint("❌ RouteService: Error in handleCompleteWorkout: \(error)")
                debugPrint("   - Error type: \(type(of: error))")
                debugPrint("   - Error description: \(error.localizedDescription)")
                print("Read Workouts: fetch error:", error)
            }
        }
    }

    // push workout payload (uses WorkoutRecordStore dedupe)
    func pushWorkout(finalWorkout : HuWorkout) async {
        debugPrint("📦 RouteService: pushWorkout called for \(finalWorkout.deviceActivityId)")
        
        debugPrint("   - Converting workout to dictionary...")
        guard let dict = finalWorkout.toDict() else {
            debugPrint("   - ❌ Failed to convert workout to dictionary")
            return
        }
        debugPrint("   - ✅ Workout converted to dictionary")
        
        // We do not wrap it in an array here since we are returning a single workout representation
        do {
            debugPrint("   - Serializing to JSON...")
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            debugPrint("   - ✅ JSON serialized, size: \(data.count) bytes")
            let deviceId = finalWorkout.deviceActivityId

            // Check local store (dedupe)
            debugPrint("   - Checking WorkoutRecordStore for dedupe...")
            let shouldPush = await WorkoutRecordStore.shared.shouldPush(deviceActivityId: deviceId, payload: data)
            debugPrint("   - shouldPush: \(shouldPush)")
            if !shouldPush {
                debugPrint("   - ⏭️ Skipping push — already pushed and unchanged for \(deviceId)")
                return
            }

            // Mark pending
            debugPrint("   - Marking workout as pending in store...")
            await WorkoutRecordStore.shared.upsertRecordPending(deviceActivityId: deviceId, payload: data)
            debugPrint("   - ✅ Marked as pending")

            debugPrint("   - Converting to UTF8 string...")
            guard let jsonString = String(data: data, encoding: .utf8) else {
                debugPrint("   - ❌ Failed to convert workout data to string")
                return
            }
            debugPrint("   - ✅ JSON string created")

            // Log workout data recorded
            debugPrint("🏋️ [WorkoutDelivery] ── WORKOUT DATA RECORDED ──────────────")
            debugPrint("🏋️ [WorkoutDelivery] DeviceActivityId: \(deviceId)")
            debugPrint("🏋️ [WorkoutDelivery] JSON payload size: \(data.count) bytes")
            if let activityType = dict["activityType"] as? String {
                debugPrint("🏋️ [WorkoutDelivery] Activity type: \(activityType)")
            }
            if let startDate = dict["startDate"] as? String {
                debugPrint("🏋️ [WorkoutDelivery] Start date: \(startDate)")
            }
            if let endDate = dict["endDate"] as? String {
                debugPrint("🏋️ [WorkoutDelivery] End date: \(endDate)")
            }
            if let duration = dict["duration"] as? Double {
                debugPrint("🏋️ [WorkoutDelivery] Duration: \(String(format: "%.1f", duration))s")
            }
            if let distance = dict["totalDistance"] as? Double {
                debugPrint("🏋️ [WorkoutDelivery] Distance: \(String(format: "%.2f", distance))m")
            }
            if let calories = dict["totalEnergyBurned"] as? Double {
                debugPrint("🏋️ [WorkoutDelivery] Calories: \(String(format: "%.1f", calories)) kcal")
            }
            debugPrint("🏋️ [WorkoutDelivery] JSON preview: \(String(jsonString.prefix(300)))...")
            debugPrint("🏋️ [WorkoutDelivery] ─────────────────────────────────────────")

            debugPrint("📤 RouteService: Calling BackgroundDeliveryManager.deliverWorkout for \(deviceId)")
            // Delegate background delivery to Manager (API vs Local vs Foreground Stream)
            await BackgroundDeliveryManager.shared.deliverWorkout(jsonString, deviceId: deviceId)
            debugPrint("✅ RouteService: deliverWorkout completed for \(deviceId)")
            
        } catch {
            debugPrint("❌ RouteService: pushWorkout JSON error: \(error)")
            debugPrint("   - Error type: \(type(of: error))")
            debugPrint("   - Error description: \(error.localizedDescription)")
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


