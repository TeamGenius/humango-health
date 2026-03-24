import Foundation
import Flutter
import HealthKit
import UIKit
import CoreLocation
import WorkoutKit

class WorkoutServiceChannel: NSObject, FlutterStreamHandler {
    private var workoutService: WorkoutService?
    private var eventSink: FlutterEventSink?
    /// Batched anchored workout reads; keep in sync with `limit` in fetch helpers.
    private let workoutAnchoredBatchLimit = 100
    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    
    // User preferences for workout filtering
    private var unImportWorkout: [String] {
        var excluded: [String] = []
        if !(UserDefaults.standard.object(forKey: UserDefaultsKeys.isImportRunning) as? Bool ?? true) {
            excluded.append("Running")
        }
        if !(UserDefaults.standard.object(forKey: UserDefaultsKeys.isImportCycling) as? Bool ?? true) {
            excluded.append("Cycling")
        }
        if !(UserDefaults.standard.object(forKey: UserDefaultsKeys.isImportSwimming) as? Bool ?? true) {
            excluded.append("Swimming")
        }
        return excluded
    }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "readWorkouts":
            handleReadWorkouts(call, result)
        case "startWorkoutMonitoring":
            handleStartMonitoring(call, result)
        case "stopWorkoutMonitoring":
            handleStopMonitoring(result)
        case "configureBackgroundDelivery":
            handleConfigureBackground(call, result)
        case "setImportPreferences":
            handleSetImportPreferences(call, result)
        case "markWorkoutsAsPushed":
            handleMarkWorkoutsAsPushed(call, result)
        case "fetchAllWorkouts":
            handleFetchAllWorkouts(call, result)
        case "getWorkoutStoreRecords":
            handleGetWorkoutStoreRecords(result)
        case "enterForeground":
            workoutService?.enterForegroundMode()
            result(nil)
        case "enterBackground":
            workoutService?.enterBackgroundMode()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleReadWorkouts(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let startISO = args["startDate"] as? String,
              let startDate = DateUtils.parseDate(from: startISO) else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid startDate", details: nil))
            return
        }
        
        // endDate is optional, defaults to current time
        let endDate: Date
        if let endISO = args["endDate"] as? String,
           let parsedEndDate = DateUtils.parseDate(from: endISO) {
            endDate = parsedEndDate
        } else {
            endDate = Date()
        }
        
        debugPrint("Read Workouts: handleReadWorkouts - Start: \(startDate), End: \(endDate)")
        
        Task {
            do {
                let workoutsJson = try await fetchWorkoutsBatched(
                    startDate: startDate,
                    endDate: endDate
                )
                DispatchQueue.main.async {
                    result(workoutsJson)
                }
            } catch {
                debugPrint("Read Workouts: handleReadWorkouts error: \(error)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "FETCH_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    // MARK: - Batched Workout Fetching
    
    private func fetchWorkoutsBatched(startDate: Date, endDate: Date) async throws -> [String] {
        var allWorkouts: [HuWorkout] = []
        var anchor: HKQueryAnchor? = nil
        var results: HKAnchoredObjectQueryDescriptor<HKWorkout>.Result
        
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )
        
        let excludedTypes = unImportWorkout
        debugPrint("Read Workouts: Excluded workout types: \(excludedTypes)")
        
        repeat {
            // Create a query descriptor that reads a batch of matching samples
            let anchorDescriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)],
                anchor: anchor,
                limit: workoutAnchoredBatchLimit
            )
            
            results = try await anchorDescriptor.result(for: healthStore)
            anchor = results.newAnchor
            
            debugPrint("Read Workouts: Fetched batch of \(results.addedSamples.count) workouts")
            
            // Process each workout in the batch
            for workout in results.addedSamples {
                debugPrint("Read Workouts: Processing workout: \(workout.uuid.uuidString) type: \(workout.workoutActivityType.name)")
                
                // Skip incomplete workouts
                guard workout.endDate > workout.startDate else {
                    debugPrint("Read Workouts: Skipping incomplete workout: \(workout.uuid.uuidString)")
                    continue
                }
                
                // Filter based on user preferences
                if excludedTypes.contains(workout.workoutActivityType.name) {
                    debugPrint("Read Workouts: Skipping due to preferences: \(workout.workoutActivityType.name)")
                    continue
                }
                
                // Process workout with route data
                do {
                    if let huWorkout = try await processWorkout(workout) {
                        allWorkouts.append(huWorkout)
                    }
                } catch {
                    debugPrint("Read Workouts: Error processing workout \(workout.uuid.uuidString): \(error)")
                }
            }
            
        } while results.addedSamples.count == workoutAnchoredBatchLimit

        debugPrint("Read Workouts: Total workouts processed: \(allWorkouts.count)")
        
        // Convert to JSON strings, with WorkoutRecordStore byte-level dedup
        // (same pattern as RouteService.pushWorkout — skip workouts already pushed via background API)
        var workoutsJson: [String] = []
        var skippedCount = 0
        for workout in allWorkouts {
            if let jsonData = workout.toJson(),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                
                let deviceId = workout.deviceActivityId
                
                // Check WorkoutRecordStore: SHA256 hash + byte size dedupe
                let shouldPush = await WorkoutRecordStore.shared.shouldPush(
                    deviceActivityId: deviceId,
                    payload: jsonData
                )
                
                if !shouldPush {
                    debugPrint("Read Workouts: ⏭️ Skipping workout \(deviceId) — already pushed and unchanged (bytes match)")
                    skippedCount += 1
                    continue
                }
                
                // Track in record store as pending (so future calls can dedupe)
                await WorkoutRecordStore.shared.upsertRecordPending(
                    deviceActivityId: deviceId,
                    payload: jsonData
                )
                
                workoutsJson.append(jsonString)
            }
        }
        
        debugPrint("Read Workouts: Returning \(workoutsJson.count) workouts (\(skippedCount) skipped — already pushed via background API)")
        return workoutsJson
    }
    
    // MARK: - Process Individual Workout
    
    private func processWorkout(_ workout: HKWorkout) async throws -> HuWorkout? {
        debugPrint("Read Workouts: Processing workout \(workout.uuid.uuidString)")
        
        // Fetch all quantity series data (gracefully handle authorization errors)
        let series: [[HKQuantitySample]]
        do {
            series = try await fetchAllQuantitySeriesForWorkout(workout)
            let totalSamples = series.reduce(0) { $0 + $1.count }
            debugPrint("Read Workouts: Fetched \(totalSamples) quantity samples across \(series.count) types")
        } catch {
            debugPrint("Read Workouts: Warning - failed to fetch quantity series for \(workout.uuid.uuidString): \(error)")
            // Continue with empty series rather than failing the entire workout
            series = []
        }
        
        // Fetch route data (gracefully handle authorization errors)
        let routes: [HKWorkoutRoute]
        do {
            routes = try await fetchWorkoutRoutes(workout)
        } catch {
            debugPrint("Read Workouts: Warning - failed to fetch routes for \(workout.uuid.uuidString): \(error)")
            routes = []
        }
        
        let locations: [CLLocation]
        do {
            locations = try await buildRouteData(from: routes)
        } catch {
            debugPrint("Read Workouts: Warning - failed to build route data for \(workout.uuid.uuidString): \(error)")
            locations = []
        }
        
        // Build metadata
        var dictMetaData = workout.metadata ?? [:]
        dictMetaData["dataSource"] = workout.sourceRevision.source.name
        dictMetaData["iosVersion"] = UIDevice.current.systemVersion
        
        debugPrint("Read Workouts: Creating HuWorkout with \(locations.count) locations and \(series.reduce(0) { $0 + $1.count }) samples")
        
        // Construct HuWorkout
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
    
    // MARK: - Helper Methods for Route & Quantity Data
    
    private func fetchWorkoutRoutes(_ workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        // Check authorization for workout routes
        let routeType = HKSeriesType.workoutRoute()
        let authStatus = healthStore.authorizationStatus(for: routeType)
        guard authStatus == .sharingAuthorized else {
            debugPrint("Read Workouts: Workout route not authorized")
            return []
        }
        
        debugPrint("Read Workouts: Fetching routes for workout \(workout.uuid.uuidString)")
        
        let pred = HKQuery.predicateForObjects(from: workout)
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(pred)],
            anchor: nil,
            limit: HKObjectQueryNoLimit
        )
        let result: HKAnchoredObjectQueryDescriptor<HKWorkoutRoute>.Result = try await desc.result(for: healthStore)
        
        debugPrint("Read Workouts: Found \(result.addedSamples.count) route(s) for workout \(workout.uuid.uuidString)")
        
        return result.addedSamples
    }
    
    private func buildRouteData(from routes: [HKWorkoutRoute]) async throws -> [CLLocation] {
        debugPrint("Read Workouts: Building route data from \(routes.count) route(s)")
        var allPoints: [CLLocation] = []
        for route in routes {
            let seq = HKWorkoutRouteQueryDescriptor(route).results(for: healthStore)
            var routePointCount = 0
            for try await loc in seq {
                allPoints.append(loc)
                routePointCount += 1
            }
            debugPrint("Read Workouts: Route \(route.uuid) contributed \(routePointCount) location points")
        }
        debugPrint("Read Workouts: Total locations extracted: \(allPoints.count)")
        return allPoints
    }
    
    private func fetchAllQuantitySeriesForWorkout(_ workout: HKWorkout) async throws -> [[HKQuantitySample]] {
        let ids: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .stepCount,
            .distanceCycling,
            .swimmingStrokeCount,
            .distanceSwimming,
            .vo2Max,
            .distanceWalkingRunning,
            .activeEnergyBurned,
            .bodyMass,
            .height,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .bodyMassIndex,
            .runningGroundContactTime,
            .runningPower,
            .runningSpeed,
            .runningStrideLength,
            .runningVerticalOscillation,
            .cyclingCadence,
            .cyclingPower,
        ]
        
        return try await withThrowingTaskGroup(of: (Int, [HKQuantitySample]).self) { group in
            for (idx, id) in ids.enumerated() {
                group.addTask {
                    guard let qType = HKObjectType.quantityType(forIdentifier: id) else {
                        return (idx, [])
                    }
                    
                    // Check authorization status before querying
                    let authStatus = self.healthStore.authorizationStatus(for: qType)
                    guard authStatus == .sharingAuthorized else {
                        // Skip this type if not authorized
                        return (idx, [])
                    }
                    
                    do {
                        let pred = HKQuery.predicateForSamples(
                            withStart: workout.startDate,
                            end: workout.endDate,
                            options: .strictEndDate
                        )
                        let descriptor = HKSampleQueryDescriptor(
                            predicates: [.sample(type: qType, predicate: pred)],
                            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
                            limit: HKObjectQueryNoLimit
                        )
                        let results = try await descriptor.result(for: self.healthStore)
                        let samples = results.compactMap { $0 as? HKQuantitySample }
                        return (idx, samples)
                    } catch {
                        // Log error but continue with empty results for this type
                        debugPrint("Read Workouts: Warning - failed to fetch \(id.rawValue): \(error.localizedDescription)")
                        return (idx, [])
                    }
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
    
    private func handleStartMonitoring(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let startISO = args["startDate"] as? String,
              let startDate = DateUtils.parseDate(from: startISO) else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid startDate", details: nil))
            return
        }
        
        if workoutService == nil {
            workoutService = WorkoutService(startDate: startDate)
            
            // Pass the eventSink to the manager so RouteService can push to it.
            WorkoutStreamDelivery.shared.attachEventSink(eventSink)
        }
        
        Task {
            await workoutService?.start()
            DispatchQueue.main.async {
                result(nil)
            }
        }
    }
    
    private func handleStopMonitoring(_ result: @escaping FlutterResult) {
        workoutService?.stopLiveUpdates()
        workoutService?.stopBackgroundMonitoring()
        workoutService = nil
        result(nil)
    }
    
    private func handleConfigureBackground(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let modeStr = args["mode"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid mode", details: nil))
            return
        }

        guard modeStr == "localStorage" else {
            result(FlutterError(code: "INVALID_ARGS", message: "Unknown mode \"\(modeStr)\". Use localStorage.", details: nil))
            return
        }

        WorkoutStreamDelivery.shared.arm()

        DispatchQueue.main.async {
            if self.workoutService == nil {
                self.autoStartIfConfigured()
            }
            result(nil)
        }
    }
    
    private func handleSetImportPreferences(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Bool] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid preferences", details: nil))
            return
        }
        
        let running = args["running"] ?? true
        let cycling = args["cycling"] ?? true
        let swimming = args["swimming"] ?? true
        
        UserDefaults.standard.set(running, forKey: UserDefaultsKeys.isImportRunning)
        UserDefaults.standard.set(cycling, forKey: UserDefaultsKeys.isImportCycling)
        UserDefaults.standard.set(swimming, forKey: UserDefaultsKeys.isImportSwimming)
        UserDefaults.standard.synchronize()
        
        debugPrint("Read Workouts: Import preferences updated - Running: \(running), Cycling: \(cycling), Swimming: \(swimming)")
        result(nil)
    }

    // MARK: - Fetch All Workouts (no dedup filter)

    /// Returns every workout in the given date range as JSON strings.
    /// Unlike readWorkouts, this does NOT check WorkoutRecordStore —
    /// all matching workouts are returned regardless of pushed state.
    private func handleFetchAllWorkouts(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let startISO = args["startDate"] as? String,
              let startDate = DateUtils.parseDate(from: startISO) else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid startDate", details: nil))
            return
        }

        let endDate: Date
        if let endISO = args["endDate"] as? String,
           let parsedEndDate = DateUtils.parseDate(from: endISO) {
            endDate = parsedEndDate
        } else {
            endDate = Date()
        }

        debugPrint("Read Workouts: fetchAllWorkouts - Start: \(startDate), End: \(endDate)")

        Task {
            do {
                let workoutsJson = try await fetchAllWorkoutsRaw(startDate: startDate, endDate: endDate)
                DispatchQueue.main.async {
                    result(workoutsJson)
                }
            } catch {
                debugPrint("Read Workouts: fetchAllWorkouts error: \(error)")
                DispatchQueue.main.async {
                    result(FlutterError(code: "FETCH_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func fetchAllWorkoutsRaw(startDate: Date, endDate: Date) async throws -> [String] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        var workoutsJson: [String] = []
        var anchor: HKQueryAnchor? = nil
        var results: HKAnchoredObjectQueryDescriptor<HKWorkout>.Result

        repeat {
            let anchorDescriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)],
                anchor: anchor,
                limit: workoutAnchoredBatchLimit
            )
            results = try await anchorDescriptor.result(for: healthStore)
            anchor = results.newAnchor

            for workout in results.addedSamples {
                guard workout.endDate > workout.startDate else { continue }
                if let huWorkout = try? await processWorkout(workout),
                   let jsonData = huWorkout.toJson(),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    workoutsJson.append(jsonString)
                }
            }
        } while results.addedSamples.count == workoutAnchoredBatchLimit

        debugPrint("Read Workouts: fetchAllWorkoutsRaw returning \(workoutsJson.count) workout(s)")
        return workoutsJson
    }

    // MARK: - Get WorkoutRecordStore Records

    /// Returns all records currently stored in WorkoutRecordStore as a list of maps.
    private func handleGetWorkoutStoreRecords(_ result: @escaping FlutterResult) {
        Task {
            let records = await WorkoutRecordStore.shared.fetchAllRecords()
            debugPrint("Read Workouts: getWorkoutStoreRecords returning \(records.count) record(s)")
            DispatchQueue.main.async {
                result(records)
            }
        }
    }

    // MARK: - Mark Workouts As Pushed

    /// Called by Flutter after successfully sending workouts to the backend.
    /// Marks each supplied deviceActivityId as pushed=true in WorkoutRecordStore
    /// so they are excluded from future readWorkouts calls.
    private func handleMarkWorkoutsAsPushed(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let ids = call.arguments as? [String], !ids.isEmpty else {
            result(FlutterError(code: "INVALID_ARGS", message: "Expected a non-empty array of deviceActivityId strings", details: nil))
            return
        }

        Task {
            for id in ids {
                await WorkoutRecordStore.shared.markPushed(deviceActivityId: id)
            }
            debugPrint("Read Workouts: ✅ Marked \(ids.count) workout(s) as pushed: \(ids)")
            await WorkoutRecordStore.shared.printAllRecords(context: "after markWorkoutsAsPushed")
            DispatchQueue.main.async {
                result(["markedCount": ids.count, "deviceActivityIds": ids])
            }
        }
    }
    
    // MARK: - Auto-Start on App Launch
    
    /// Auto-starts workout monitoring if `configureBackgroundDelivery` has armed stream delivery.
    /// Called from HumangoHealthPlugin.register() on every app launch/background wake.
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            debugPrint("Read Workouts: Auto-start skipped — user not logged in")
            return
        }
        guard WorkoutStreamDelivery.shared.isArmedForAutoStart else {
            debugPrint("Read Workouts: Auto-start skipped — workout stream delivery not armed (call configureBackgroundDelivery)")
            return
        }
        guard workoutService == nil else {
            debugPrint("Read Workouts: Auto-start skipped — monitoring already active")
            return
        }
        
        let startDate = Date().addingTimeInterval(-24 * 60 * 60) // 24h lookback
        workoutService = WorkoutService(startDate: startDate)
        WorkoutStreamDelivery.shared.attachEventSink(eventSink)

        Task {
            await workoutService?.start()
            debugPrint("Read Workouts: ✅ Auto-started workout monitoring (stream/pending) from \(startDate)")
        }
    }

    /// Stops all active monitoring and clears background delivery configuration.
    /// Called on user logout to ensure no background activity continues.
    func stopAndClearAll() {
        workoutService?.stopLiveUpdates()
        workoutService?.stopBackgroundMonitoring()
        workoutService = nil
        WorkoutStreamDelivery.shared.clearConfiguration()
        WorkoutStreamDelivery.shared.attachEventSink(nil)
        debugPrint("Read Workouts: ✅ Stopped monitoring and cleared all background config on logout")
    }
    
    // MARK: - FlutterStreamHandler
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        // If startMonitoring was already called, attach it now
        WorkoutStreamDelivery.shared.attachEventSink(events)
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        WorkoutStreamDelivery.shared.attachEventSink(nil)
        return nil
    }
}
