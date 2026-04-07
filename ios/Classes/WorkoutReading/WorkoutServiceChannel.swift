import Foundation
import Flutter
import HealthKit
import UIKit
import CoreLocation
import WorkoutKit

class WorkoutServiceChannel: NSObject {
    private var workoutService: WorkoutService?
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
        let loginOptional = Set(["stopWorkoutMonitoring"])
        if !loginOptional.contains(call.method) {
            guard UserAuthStateManager.shared.guardLoggedInForHealthData(result: result) else { return }
        }
        switch call.method {
        case "readWorkouts":
            handleReadWorkouts(call, result)
        case "startWorkoutMonitoring":
            handleStartMonitoring(call, result)
        case "stopWorkoutMonitoring":
            handleStopMonitoring(result)
        case "setImportPreferences":
            handleSetImportPreferences(call, result)
        case "fetchAllWorkouts":
            handleFetchAllWorkouts(call, result)
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
        SleepRemoteLogger.log(.info, step: "readWorkouts.start", message: "readWorkouts requested", context: [
            "class": "WorkoutServiceChannel",
            "method": "handleReadWorkouts",
            "startDate": startDate.description,
            "endDate": endDate.description,
        ], subsystem: "WorkoutReading")
        
        Task {
            do {
                let workoutsJson = try await fetchWorkoutsBatched(
                    startDate: startDate,
                    endDate: endDate
                )
                SleepRemoteLogger.log(.info, step: "readWorkouts.complete", message: "readWorkouts completed", context: [
                    "class": "WorkoutServiceChannel",
                    "method": "handleReadWorkouts",
                    "count": "\(workoutsJson.count)",
                ], subsystem: "WorkoutReading")
                DispatchQueue.main.async {
                    result(workoutsJson)
                }
            } catch {
                debugPrint("Read Workouts: handleReadWorkouts error: \(error)")
                SleepRemoteLogger.log(.error, step: "readWorkouts.error", message: "readWorkouts failed", context: [
                    "class": "WorkoutServiceChannel",
                    "method": "handleReadWorkouts",
                    "error": error.localizedDescription,
                ], subsystem: "WorkoutReading")
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
        var batchNumber = 0
        
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )
        
        let excludedTypes = unImportWorkout
        debugPrint("Read Workouts: Excluded workout types: \(excludedTypes)")
        SleepRemoteLogger.log(.info, step: "fetchBatched.start", message: "starting batched workout fetch", context: [
            "class": "WorkoutServiceChannel",
            "method": "fetchWorkoutsBatched",
            "startDate": startDate.description,
            "endDate": endDate.description,
            "excludedTypes": excludedTypes.joined(separator: ","),
        ], subsystem: "WorkoutReading")
        
        repeat {
            batchNumber += 1
            // Create a query descriptor that reads a batch of matching samples
            let anchorDescriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)],
                anchor: anchor,
                limit: workoutAnchoredBatchLimit
            )
            
            results = try await anchorDescriptor.result(for: healthStore)
            anchor = results.newAnchor
            
            debugPrint("Read Workouts: Fetched batch of \(results.addedSamples.count) workouts")
            SleepRemoteLogger.log(.info, step: "fetchBatched.batch", message: "batch fetched", context: [
                "class": "WorkoutServiceChannel",
                "method": "fetchWorkoutsBatched",
                "batch": "\(batchNumber)",
                "count": "\(results.addedSamples.count)",
            ], subsystem: "WorkoutReading")
            
            // Process each workout in the batch
            for workout in results.addedSamples {
                debugPrint("Read Workouts: Processing workout: \(workout.uuid.uuidString) type: \(workout.workoutActivityType.name)")
                
                // Skip incomplete workouts
                guard workout.endDate > workout.startDate else {
                    debugPrint("Read Workouts: Skipping incomplete workout: \(workout.uuid.uuidString)")
                    SleepRemoteLogger.log(.warn, step: "fetchBatched.skip", message: "skipping incomplete workout", context: [
                        "class": "WorkoutServiceChannel",
                        "method": "fetchWorkoutsBatched",
                        "uuid": workout.uuid.uuidString,
                        "reason": "endDate <= startDate",
                    ], subsystem: "WorkoutReading")
                    continue
                }
                
                // Filter based on user preferences
                if excludedTypes.contains(workout.workoutActivityType.name) {
                    debugPrint("Read Workouts: Skipping due to preferences: \(workout.workoutActivityType.name)")
                    SleepRemoteLogger.log(.info, step: "fetchBatched.skip", message: "skipping excluded workout type", context: [
                        "class": "WorkoutServiceChannel",
                        "method": "fetchWorkoutsBatched",
                        "uuid": workout.uuid.uuidString,
                        "type": workout.workoutActivityType.name,
                        "reason": "excludedByPreference",
                    ], subsystem: "WorkoutReading")
                    continue
                }
                
                // Process workout with route data
                do {
                    if let huWorkout = try await processWorkout(workout) {
                        allWorkouts.append(huWorkout)
                    }
                } catch {
                    debugPrint("Read Workouts: Error processing workout \(workout.uuid.uuidString): \(error)")
                    SleepRemoteLogger.log(.error, step: "fetchBatched.processError", message: "error processing workout", context: [
                        "class": "WorkoutServiceChannel",
                        "method": "fetchWorkoutsBatched",
                        "uuid": workout.uuid.uuidString,
                        "error": error.localizedDescription,
                    ], subsystem: "WorkoutReading")
                }
            }
            
        } while results.addedSamples.count == workoutAnchoredBatchLimit

        debugPrint("Read Workouts: Total workouts processed: \(allWorkouts.count)")
        
        var workoutsJson: [String] = []
        for workout in allWorkouts {
            if let jsonData = workout.toJson(),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                workoutsJson.append(jsonString)
                SleepRemoteLogger.log(.info, step: "fetchBatched.payload", message: "workout payload ready", context: [
                    "class": "WorkoutServiceChannel",
                    "method": "fetchWorkoutsBatched",
                    "uuid": workout.deviceActivityId,
                    "payload": jsonString,
                ], subsystem: "WorkoutReading")
            }
        }
        
        debugPrint("Read Workouts: Returning \(workoutsJson.count) workouts")
        SleepRemoteLogger.log(.info, step: "fetchBatched.complete", message: "batched fetch complete", context: [
            "class": "WorkoutServiceChannel",
            "method": "fetchWorkoutsBatched",
            "totalBatches": "\(batchNumber)",
            "totalWorkouts": "\(workoutsJson.count)",
        ], subsystem: "WorkoutReading")
        return workoutsJson
    }
    
    // MARK: - Process Individual Workout
    
    private func processWorkout(_ workout: HKWorkout) async throws -> HuWorkout? {
        let uuid = workout.uuid.uuidString
        debugPrint("Read Workouts: Processing workout \(uuid)")
        SleepRemoteLogger.log(.info, step: "processWorkout.start", message: "processing workout", context: [
            "class": "WorkoutServiceChannel",
            "method": "processWorkout",
            "uuid": uuid,
            "type": workout.workoutActivityType.name,
            "start": workout.startDate.description,
            "end": workout.endDate.description,
        ], subsystem: "WorkoutReading")
        
        // Fetch all quantity series data (gracefully handle authorization errors)
        let series: [[HKQuantitySample]]
        do {
            series = try await fetchAllQuantitySeriesForWorkout(workout)
            let totalSamples = series.reduce(0) { $0 + $1.count }
            debugPrint("Read Workouts: Fetched \(totalSamples) quantity samples across \(series.count) types")
            SleepRemoteLogger.log(.info, step: "processWorkout.series", message: "quantity series fetched", context: [
                "class": "WorkoutServiceChannel",
                "method": "processWorkout",
                "uuid": uuid,
                "totalSamples": "\(totalSamples)",
                "seriesTypes": "\(series.count)",
            ], subsystem: "WorkoutReading")
        } catch {
            debugPrint("Read Workouts: Warning - failed to fetch quantity series for \(uuid): \(error)")
            SleepRemoteLogger.log(.warn, step: "processWorkout.seriesError", message: "failed to fetch quantity series", context: [
                "class": "WorkoutServiceChannel",
                "method": "processWorkout",
                "uuid": uuid,
                "error": error.localizedDescription,
            ], subsystem: "WorkoutReading")
            // Continue with empty series rather than failing the entire workout
            series = []
        }
        
        // Fetch route data (gracefully handle authorization errors)
        let routes: [HKWorkoutRoute]
        do {
            routes = try await fetchWorkoutRoutes(workout)
            SleepRemoteLogger.log(.info, step: "processWorkout.routes", message: "routes fetched", context: [
                "class": "WorkoutServiceChannel",
                "method": "processWorkout",
                "uuid": uuid,
                "routeCount": "\(routes.count)",
            ], subsystem: "WorkoutReading")
        } catch {
            debugPrint("Read Workouts: Warning - failed to fetch routes for \(uuid): \(error)")
            SleepRemoteLogger.log(.warn, step: "processWorkout.routesError", message: "failed to fetch routes", context: [
                "class": "WorkoutServiceChannel",
                "method": "processWorkout",
                "uuid": uuid,
                "error": error.localizedDescription,
            ], subsystem: "WorkoutReading")
            routes = []
        }
        
        let locations: [CLLocation]
        do {
            locations = try await buildRouteData(from: routes)
            SleepRemoteLogger.log(.info, step: "processWorkout.locations", message: "route locations built", context: [
                "class": "WorkoutServiceChannel",
                "method": "processWorkout",
                "uuid": uuid,
                "locationCount": "\(locations.count)",
            ], subsystem: "WorkoutReading")
        } catch {
            debugPrint("Read Workouts: Warning - failed to build route data for \(uuid): \(error)")
            SleepRemoteLogger.log(.warn, step: "processWorkout.locationsError", message: "failed to build route locations", context: [
                "class": "WorkoutServiceChannel",
                "method": "processWorkout",
                "uuid": uuid,
                "error": error.localizedDescription,
            ], subsystem: "WorkoutReading")
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
        
        let payloadString: String
        if let jsonData = huWorkout.toJson(), let jsonString = String(data: jsonData, encoding: .utf8) {
            payloadString = jsonString
        } else {
            payloadString = "{}"
        }
        SleepRemoteLogger.log(.info, step: "processWorkout.complete", message: "workout processed successfully", context: [
            "class": "WorkoutServiceChannel",
            "method": "processWorkout",
            "uuid": uuid,
            "type": workout.workoutActivityType.name,
            "locationCount": "\(locations.count)",
            "totalSamples": "\(series.reduce(0) { $0 + $1.count })",
            "payload": payloadString,
        ], subsystem: "WorkoutReading")
        
        return huWorkout
    }
    
    // MARK: - Helper Methods for Route & Quantity Data
    
    private func fetchWorkoutRoutes(_ workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        // Note: authorizationStatus(for:) only reflects *write* permission.
        // Read permission is intentionally hidden by HealthKit — just run the query
        // and it returns empty results if the user hasn't granted read access.
        let routeUUID = workout.uuid.uuidString
        debugPrint("Read Workouts: Fetching routes for workout \(routeUUID)")
        SleepRemoteLogger.log(.info, step: "fetchRoutes.start", message: "fetching workout routes", context: [
            "class": "WorkoutServiceChannel",
            "method": "fetchWorkoutRoutes",
            "uuid": routeUUID,
        ], subsystem: "WorkoutReading")
        
        let pred = HKQuery.predicateForObjects(from: workout)
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(pred)],
            anchor: nil,
            limit: HKObjectQueryNoLimit
        )
        let result: HKAnchoredObjectQueryDescriptor<HKWorkoutRoute>.Result = try await desc.result(for: healthStore)
        
        debugPrint("Read Workouts: Found \(result.addedSamples.count) route(s) for workout \(routeUUID)")
        SleepRemoteLogger.log(.info, step: "fetchRoutes.complete", message: "workout routes fetched", context: [
            "class": "WorkoutServiceChannel",
            "method": "fetchWorkoutRoutes",
            "uuid": routeUUID,
            "routeCount": "\(result.addedSamples.count)",
        ], subsystem: "WorkoutReading")
        
        return result.addedSamples
    }
    
    private func buildRouteData(from routes: [HKWorkoutRoute]) async throws -> [CLLocation] {
        debugPrint("Read Workouts: Building route data from \(routes.count) route(s)")
        SleepRemoteLogger.log(.info, step: "buildRouteData.start", message: "building route location data", context: [
            "class": "WorkoutServiceChannel",
            "method": "buildRouteData",
            "routeCount": "\(routes.count)",
        ], subsystem: "WorkoutReading")
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
        SleepRemoteLogger.log(.info, step: "buildRouteData.complete", message: "route location data built", context: [
            "class": "WorkoutServiceChannel",
            "method": "buildRouteData",
            "totalLocations": "\(allPoints.count)",
        ], subsystem: "WorkoutReading")
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
                    // Note: authorizationStatus(for:) only reflects *write* permission.
                    // Read permission is intentionally hidden by HealthKit — just run the
                    // query and handle errors gracefully below.
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
                        SleepRemoteLogger.log(.warn, step: "fetchQuantitySeries.typeError", message: "failed to fetch quantity type", context: [
                            "class": "WorkoutServiceChannel",
                            "method": "fetchAllQuantitySeriesForWorkout",
                            "type": id.rawValue,
                            "error": error.localizedDescription,
                        ], subsystem: "WorkoutReading")
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
            SleepRemoteLogger.log(.error, step: "startMonitoring.parse", message: "missing or invalid startDate", context: ["class": "WorkoutServiceChannel", "method": "handleStartMonitoring"], subsystem: "WorkoutReading")
            result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid startDate", details: nil))
            return
        }
        
        if workoutService == nil {
            SleepRemoteLogger.log(.info, step: "startMonitoring.start", message: "starting workout monitoring", context: [
                "class": "WorkoutServiceChannel",
                "method": "handleStartMonitoring",
                "startDate": startDate.description,
            ], subsystem: "WorkoutReading")
            workoutService = WorkoutService(startDate: startDate)
        } else {
            SleepRemoteLogger.log(.info, step: "startMonitoring.alreadyActive", message: "monitoring already active — reusing existing service", context: [
                "class": "WorkoutServiceChannel",
                "method": "handleStartMonitoring",
            ], subsystem: "WorkoutReading")
        }
        
        Task {
            await workoutService?.start()
            DispatchQueue.main.async {
                result(nil)
            }
        }
    }
    
    private func handleStopMonitoring(_ result: @escaping FlutterResult) {
        SleepRemoteLogger.log(.info, step: "stopMonitoring", message: "stopping workout monitoring", context: ["class": "WorkoutServiceChannel", "method": "handleStopMonitoring"], subsystem: "WorkoutReading")
        workoutService?.stopLiveUpdates()
        workoutService?.stopBackgroundMonitoring()
        workoutService = nil
        result(nil)
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
        SleepRemoteLogger.log(.info, step: "setImportPreferences", message: "import preferences updated", context: [
            "class": "WorkoutServiceChannel",
            "method": "handleSetImportPreferences",
            "running": "\(running)",
            "cycling": "\(cycling)",
            "swimming": "\(swimming)",
        ], subsystem: "WorkoutReading")
        result(nil)
    }

    // MARK: - Fetch All Workouts (no preference filter)

    /// Returns every workout in the given date range as JSON strings.
    /// Unlike readWorkouts, this does NOT apply the user's import preferences —
    /// all workout types are returned.
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
        SleepRemoteLogger.log(.info, step: "fetchAllWorkouts.start", message: "fetchAllWorkouts requested", context: [
            "class": "WorkoutServiceChannel",
            "method": "handleFetchAllWorkouts",
            "startDate": startDate.description,
            "endDate": endDate.description,
        ], subsystem: "WorkoutReading")

        Task {
            do {
                let workoutsJson = try await fetchAllWorkoutsRaw(startDate: startDate, endDate: endDate)
                SleepRemoteLogger.log(.info, step: "fetchAllWorkouts.complete", message: "fetchAllWorkouts completed", context: [
                    "class": "WorkoutServiceChannel",
                    "method": "handleFetchAllWorkouts",
                    "count": "\(workoutsJson.count)",
                ], subsystem: "WorkoutReading")
                DispatchQueue.main.async {
                    result(workoutsJson)
                }
            } catch {
                debugPrint("Read Workouts: fetchAllWorkouts error: \(error)")
                SleepRemoteLogger.log(.error, step: "fetchAllWorkouts.error", message: "fetchAllWorkouts failed", context: [
                    "class": "WorkoutServiceChannel",
                    "method": "handleFetchAllWorkouts",
                    "error": error.localizedDescription,
                ], subsystem: "WorkoutReading")
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
        var batchNumberRaw = 0

        SleepRemoteLogger.log(.info, step: "fetchAllRaw.start", message: "starting fetchAllWorkoutsRaw", context: [
            "class": "WorkoutServiceChannel",
            "method": "fetchAllWorkoutsRaw",
            "startDate": startDate.description,
            "endDate": endDate.description,
        ], subsystem: "WorkoutReading")

        repeat {
            batchNumberRaw += 1
            let anchorDescriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)],
                anchor: anchor,
                limit: workoutAnchoredBatchLimit
            )
            results = try await anchorDescriptor.result(for: healthStore)
            anchor = results.newAnchor
            SleepRemoteLogger.log(.info, step: "fetchAllRaw.batch", message: "batch fetched", context: [
                "class": "WorkoutServiceChannel",
                "method": "fetchAllWorkoutsRaw",
                "batch": "\(batchNumberRaw)",
                "count": "\(results.addedSamples.count)",
            ], subsystem: "WorkoutReading")

            for workout in results.addedSamples {
                guard workout.endDate > workout.startDate else {
                    SleepRemoteLogger.log(.warn, step: "fetchAllRaw.skip", message: "skipping incomplete workout", context: [
                        "class": "WorkoutServiceChannel",
                        "method": "fetchAllWorkoutsRaw",
                        "uuid": workout.uuid.uuidString,
                        "reason": "endDate <= startDate",
                    ], subsystem: "WorkoutReading")
                    continue
                }
                if let huWorkout = try? await processWorkout(workout),
                   let jsonData = huWorkout.toJson(),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    workoutsJson.append(jsonString)
                    SleepRemoteLogger.log(.info, step: "fetchAllRaw.payload", message: "workout payload ready", context: [
                        "class": "WorkoutServiceChannel",
                        "method": "fetchAllWorkoutsRaw",
                        "uuid": huWorkout.deviceActivityId,
                        "payload": jsonString,
                    ], subsystem: "WorkoutReading")
                }
            }
        } while results.addedSamples.count == workoutAnchoredBatchLimit

        debugPrint("Read Workouts: fetchAllWorkoutsRaw returning \(workoutsJson.count) workout(s)")
        SleepRemoteLogger.log(.info, step: "fetchAllRaw.complete", message: "fetchAllWorkoutsRaw complete", context: [
            "class": "WorkoutServiceChannel",
            "method": "fetchAllWorkoutsRaw",
            "totalBatches": "\(batchNumberRaw)",
            "totalWorkouts": "\(workoutsJson.count)",
        ], subsystem: "WorkoutReading")
        return workoutsJson
    }

    // MARK: - Auto-Start on App Launch
    
    /// Auto-starts workout monitoring when the user is logged in and a delegate is configured.
    /// Called from HumangoHealthPlugin.startAllBackgroundMonitoring().
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            debugPrint("[Humango] WorkoutService: autoStart skipped — user not logged in")
            SleepRemoteLogger.log(.warn, step: "workout.autoStart", message: "skipped — user not logged in", context: ["class": "WorkoutServiceChannel", "method": "autoStartIfConfigured"], subsystem: "WorkoutService")
            return
        }
        guard HumangoHealthPlugin.delegate != nil else {
            debugPrint("[Humango] WorkoutService: autoStart skipped — no delegate configured")
            SleepRemoteLogger.log(.warn, step: "workout.autoStart", message: "skipped — delegate nil", context: ["class": "WorkoutServiceChannel", "method": "autoStartIfConfigured"], subsystem: "WorkoutService")
            return
        }
        guard workoutService == nil else {
            debugPrint("[Humango] WorkoutService: autoStart skipped — monitoring already active")
            SleepRemoteLogger.log(.info, step: "workout.autoStart", message: "skipped — already active", context: ["class": "WorkoutServiceChannel", "method": "autoStartIfConfigured"], subsystem: "WorkoutService")
            return
        }
        
        let startDate = Date().addingTimeInterval(-24 * 60 * 60) // 24h lookback
        let mode = AppLifecycleManager.shared.isInForeground ? "foreground" : "background"
        SleepRemoteLogger.log(.info, step: "workout.autoStart", message: "starting", context: ["class": "WorkoutServiceChannel", "method": "autoStartIfConfigured", "mode": mode], subsystem: "WorkoutService")
        workoutService = WorkoutService(startDate: startDate)

        Task {
            await workoutService?.start()
            debugPrint("[Humango] WorkoutService: ✅ Auto-started workout monitoring (\(mode)) from \(startDate)")
            SleepRemoteLogger.log(.info, step: "workout.autoStart", message: "started", context: [
                "class": "WorkoutServiceChannel",
                "method": "autoStartIfConfigured",
                "mode": mode,
                "startDate": startDate.description,
            ], subsystem: "WorkoutService")
        }
    }

    /// Stops all active monitoring.
    /// Called on user logout to ensure no background activity continues.
    func stopAndClearAll() {
        workoutService?.stopLiveUpdates()
        workoutService?.stopBackgroundMonitoring()
        workoutService = nil
        debugPrint("[Humango] WorkoutService: ✅ Stopped monitoring on logout")
        SleepRemoteLogger.log(.info, step: "workout.stopAll", message: "stopped on logout", context: ["class": "WorkoutServiceChannel", "method": "stopAndClearAll"], subsystem: "WorkoutService")
    }
}
