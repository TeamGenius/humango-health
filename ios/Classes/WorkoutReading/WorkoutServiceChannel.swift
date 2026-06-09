import Foundation
import Flutter
import HealthKit
import UIKit
import CoreLocation

public class WorkoutServiceChannel: NSObject {
    public static let shared = WorkoutServiceChannel()
    private override init() { super.init() }

    private var workoutService: WorkoutService?
    /// Batched anchored workout reads; keep in sync with `limit` in fetch helpers.
    private let workoutAnchoredBatchLimit = 100
    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "readWorkouts":
            handleReadWorkouts(call, result)
        case "startWorkoutMonitoring":
            handleStartMonitoring(call, result)
        case "stopWorkoutMonitoring":
            handleStopMonitoring(result)

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
        var batchNumber = 0
        
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: []
        )
        
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
            
            // Process each workout in the batch
            for workout in results.addedSamples {
                debugPrint("Read Workouts: Processing workout: \(workout.uuid.uuidString) type: \(workout.workoutActivityType.name)")
                // Skip incomplete workouts
                guard workout.endDate > workout.startDate else {
                    debugPrint("Read Workouts: Skipping incomplete workout: \(workout.uuid.uuidString)")
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
        
        var workoutsJson: [String] = []
        for workout in allWorkouts {
            if let jsonData = workout.toJson(),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                workoutsJson.append(jsonString)
            }
        }
        
        debugPrint("Read Workouts: Returning \(workoutsJson.count) workouts")
        return workoutsJson
    }
    
    // MARK: - Process Individual Workout
    
    private func processWorkout(_ workout: HKWorkout) async throws -> HuWorkout? {
        let uuid = workout.uuid.uuidString
        debugPrint("Read Workouts: Processing workout \(uuid)")

        // Fetch all quantity series data (gracefully handle authorization errors)
        let series: [[HKQuantitySample]]
        do {
            series = try await fetchAllQuantitySeriesForWorkout(workout)
            let totalSamples = series.reduce(0) { $0 + $1.count }
            debugPrint("Read Workouts: Fetched \(totalSamples) quantity samples across \(series.count) types")
        } catch {
            debugPrint("Read Workouts: Warning - failed to fetch quantity series for \(uuid): \(error)")
            // Continue with empty series rather than failing the entire workout
            series = []
        }
        
        // Fetch route data (gracefully handle authorization errors)
        let routes: [HKWorkoutRoute]
        do {
            routes = try await fetchWorkoutRoutes(workout)
        } catch {
            debugPrint("Read Workouts: Warning - failed to fetch routes for \(uuid): \(error)")
            routes = []
        }
        
        let locations: [CLLocation]
        do {
            locations = try await buildRouteData(from: routes)
        } catch {
            debugPrint("Read Workouts: Warning - failed to build route data for \(uuid): \(error)")
            locations = []
        }
        
        // Build metadata
        var dictMetaData = workout.metadata ?? [:]
        dictMetaData["dataSource"] = workout.sourceRevision.source.name
        dictMetaData["sourceBundleId"] = workout.sourceRevision.source.bundleIdentifier ?? ""
        dictMetaData["iosVersion"] = UIDevice.current.systemVersion
        // Stamp isUserEnteredWorkout — backend uses this to decide how to handle the workout.
        // HKWasUserEntered is stored as an ObjC BOOL boxed in NSNumber; in Swift's [String:Any]
        // it may surface as NSNumber or Bool depending on the runtime path, so try both.
        let _hkUserEntered = workout.metadata?[HKMetadataKeyWasUserEntered]
        let isUserEntered = (_hkUserEntered as? NSNumber)?.boolValue
                         ?? (_hkUserEntered as? Bool)
                         ?? false
        dictMetaData["isUserEnteredWorkout"] = isUserEntered

        // ── DEBUG: raw HK metadata ────────────────────────────────────────
        debugPrint("[isUserEnteredWorkout] uuid=\(workout.uuid.uuidString)")
        debugPrint("[isUserEnteredWorkout] HKMetadataKeyWasUserEntered raw value = \(String(describing: _hkUserEntered))")
        debugPrint("[isUserEnteredWorkout] type = \(type(of: _hkUserEntered as Any))")
        debugPrint("[isUserEnteredWorkout] resolved isUserEntered = \(isUserEntered)")
        debugPrint("[isUserEnteredWorkout] full raw metadata = \(String(describing: workout.metadata))")
        // ─────────────────────────────────────────────────────────────────

        dictMetaData["isScheduledWorkout"] = false

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
        // Note: authorizationStatus(for:) only reflects *write* permission.
        // Read permission is intentionally hidden by HealthKit — just run the query
        // and it returns empty results if the user hasn't granted read access.
        let routeUUID = workout.uuid.uuidString
        debugPrint("Read Workouts: Fetching routes for workout \(routeUUID)")
        
        let pred = HKQuery.predicateForObjects(from: workout)
        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.workoutRoute(pred)],
            anchor: nil,
            limit: HKObjectQueryNoLimit
        )
        let result: HKAnchoredObjectQueryDescriptor<HKWorkoutRoute>.Result = try await desc.result(for: healthStore)
        
        debugPrint("Read Workouts: Found \(result.addedSamples.count) route(s) for workout \(routeUUID)")
        
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

        // Idempotent — if monitoring is already running, nothing to do.
        guard workoutService == nil else {
            result(nil)
            return
        }

        workoutService = WorkoutService(startDate: startDate)

        // In background: register HKObserverQuery synchronously BEFORE the async Task
        // so HealthKit can fire the handler even if iOS suspends us before the Task runs.
        if !AppLifecycleManager.shared.isInForeground {
            workoutService?.prepareBackgroundObserver()
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
        var batchNumberRaw = 0


        repeat {
            batchNumberRaw += 1
            let anchorDescriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)],
                anchor: anchor,
                limit: workoutAnchoredBatchLimit
            )
            results = try await anchorDescriptor.result(for: healthStore)
            anchor = results.newAnchor

            for workout in results.addedSamples {
                guard workout.endDate > workout.startDate else {
                    continue
                }
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

    // MARK: - Start Monitoring (called by HumangoHealthPlugin on every app open)

    /// Starts workout monitoring. Call this on every app open after `HumangoHealthPlugin.delegate` is set.
    /// Idempotent — if monitoring is already running, this is a no-op.
    /// In background mode the HKObserverQuery is registered synchronously so HealthKit
    /// can fire the handler even if the app is suspended before the async init completes.
    public func startMonitoring() {
        guard workoutService == nil else {
            debugPrint("[Humango] WorkoutService: startMonitoring skipped — monitoring already active")
            return
        }

        let startDate = Date().addingTimeInterval(-24 * 60 * 60) // 24h lookback
        let mode = AppLifecycleManager.shared.isInForeground ? "foreground" : "background"
        workoutService = WorkoutService(startDate: startDate)

        // In background: register HKObserverQuery synchronously BEFORE the async Task
        // so HealthKit can fire the handler even if iOS suspends us before the Task runs.
        if !AppLifecycleManager.shared.isInForeground {
            workoutService?.prepareBackgroundObserver()
        }

        Task {
            await workoutService?.start()
            debugPrint("[Humango] WorkoutService: ✅ monitoring started (\(mode)) from \(startDate)")
        }
    }

    // MARK: - Public Native iOS Workout Read API

    /// Fetch completed workouts within a date range and return them as JSON strings.
    /// All workout types are returned — filtering is the client's responsibility.
    ///
    /// ```swift
    /// let end   = Date()
    /// let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
    ///
    /// let workouts = try await HumangoHealthPlugin.shared?.readWorkouts(
    ///     startDate: start,
    ///     endDate: end
    /// ) ?? []
    ///
    /// for json in workouts {
    ///     // each element is a JSON string — decode with JSONSerialization or Codable
    ///     print(json)
    /// }
    /// ```
    func readWorkouts(startDate: Date, endDate: Date) async throws -> [String] {
        let results = try await fetchWorkoutsBatched(startDate: startDate, endDate: endDate)
        return results
    }

    /// Fetch ALL workouts within a date range as JSON strings, ignoring import
    /// preferences. Use this for full audits or re-syncs.
    ///
    /// ```swift
    /// let all = try await HumangoHealthPlugin.shared?.fetchAllWorkouts(
    ///     startDate: start,
    ///     endDate: end
    /// ) ?? []
    /// ```
    func fetchAllWorkouts(startDate: Date, endDate: Date) async throws -> [String] {
        let results = try await fetchAllWorkoutsRaw(startDate: startDate, endDate: endDate)
        return results
    }

    /// Stops all active monitoring.
    /// Called on user logout to ensure no background activity continues.
    func stopAndClearAll() {
        workoutService?.invalidate()
        workoutService = nil
        debugPrint("[Humango] WorkoutService: ✅ Stopped monitoring on logout")
    }
}
