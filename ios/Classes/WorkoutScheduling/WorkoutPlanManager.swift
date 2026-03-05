//
//  WorkoutPlanManager.swift
//  humango_health
//

import Flutter
import WorkoutKit
import Foundation

// MARK: - WorkoutPlanManager

public class WorkoutPlanManager: NSObject {
    static let shared = WorkoutPlanManager()
    
    private let store = ScheduledWorkoutStore.shared
    private let builder = WorkoutPlanBuilder()
    
    // Set by plugin registration
    public var eventSink: FlutterEventSink?

    // MARK: - Method Channel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "scheduleWorkoutsFromFlutter":
            guard let args = call.arguments as? [[String: Any]] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected array of workout dictionaries", details: nil))
                return
            }
            
            if #available(iOS 17.0, *) {
                Task {
                    do {
                        if #available(iOS 17.4, *) {
                           let scheduledRecords = try await scheduleWorkouts(jsonArray: args)
                           DispatchQueue.main.async {
                               result(["scheduledRecords": scheduledRecords])
                           }
                        } else {
                            DispatchQueue.main.async {
                                result(FlutterError(code: "UNSUPPORTED", message: "Workout scheduling requires iOS 17.4+", details: nil))
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            result(FlutterError(code: "SCHEDULE_ERROR", message: error.localizedDescription, details: nil))
                        }
                    }
                }
            } else {
                result(FlutterError(code: "UNSUPPORTED", message: "WorkoutKit requires iOS 17.0+", details: nil))
            }
            
        case "clearAppleScheduledWorkouts":
           store.clearAll()
           result(true)
            
        case "requestAuthorizationForWorkoutPush":
            if #available(iOS 17.0, *) {
                Task {
                    do {
                        let authResult = try await self.requestWorkoutPushAuthorization()
                        DispatchQueue.main.async {
                            result(authResult)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            result(FlutterError(code: "AUTH_ERROR", message: error.localizedDescription, details: nil))
                        }
                    }
                }
            } else {
                result(FlutterError(code: "UNSUPPORTED", message: "WorkoutKit requires iOS 17.0+", details: nil))
            }
            
        case "getScheduledWorkouts":
            if #available(iOS 17.0, *) {
                Task {
                    do {
                        let workouts = await self.getScheduledWorkouts()
                        DispatchQueue.main.async {
                            result(workouts)
                        }
                    }
                }
            } else {
                result(FlutterError(code: "UNSUPPORTED", message: "WorkoutKit requires iOS 17.0+", details: nil))
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Get Scheduled Workouts
    
    @available(iOS 17.0, *)
    private func getScheduledWorkouts() async -> [[String: Any]] {
        let scheduledWorkouts = await WorkoutScheduler.shared.scheduledWorkouts
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var workoutsList: [[String: Any]] = []
        
        for scheduledWorkout in scheduledWorkouts {
            let plan = scheduledWorkout.plan
            let planId = plan.id.uuidString
            let dateComponents = scheduledWorkout.date
            
            // Convert DateComponents to Date
            let scheduledDate = Calendar.current.date(from: dateComponents)
            let scheduledDateString = scheduledDate != nil ? isoFormatter.string(from: scheduledDate!) : nil
            
            // Extract workout details
            var workoutInfo: [String: Any] = [
                "id": planId,
                "workoutPlanId": planId
            ]
            
            if let dateStr = scheduledDateString {
                workoutInfo["scheduledDate"] = dateStr
            }
            
            // Try to get workout name and activity type from the plan
            if let customWorkout = plan.workout as? CustomWorkout {
                workoutInfo["activityType"] = String(describing: customWorkout.activity)
                if let displayName = customWorkout.displayName {
                    workoutInfo["name"] = displayName
                }
            } else if let goalWorkout = plan.workout as? SingleGoalWorkout {
                workoutInfo["activityType"] = String(describing: goalWorkout.activity)
            } else if let swimBikeRunWorkout = plan.workout as? SwimBikeRunWorkout {
                workoutInfo["activityType"] = "Triathlon"
            }
            
            // Try to match with local store record using WorkoutPlan ID and include full JSON
            if let localWorkoutId = store.findWorkoutByPlanId(planId) {
                workoutInfo["workoutId"] = localWorkoutId
                if let storedRecord = store.getRecord(for: localWorkoutId) {
                    // Extract additional info from stored JSON
                    if let summary = storedRecord.workoutJson["summary"]?.value as? [String: Any],
                       let name = summary["name"] as? String {
                        workoutInfo["name"] = name
                    }
                    // Include the full stored JSON
                    let jsonDict = storedRecord.workoutJson.mapValues { $0.value }
                    workoutInfo["workoutJson"] = jsonDict
                    workoutInfo["jsonSizeBytes"] = storedRecord.jsonBytes.count
                }
            }
            
            workoutsList.append(workoutInfo)
        }
        
        return workoutsList
    }
    
    // MARK: - Workout Push Authorization
    
    @available(iOS 17.0, *)
    private func requestWorkoutPushAuthorization() async throws -> [String: Any] {
        let authState = await WorkoutScheduler.shared.authorizationState
        
        switch authState {
        case .notDetermined:
            do {
                try await WorkoutScheduler.shared.requestAuthorization()
                let newState = await WorkoutScheduler.shared.authorizationState
                return authorizationStatusMap(from: newState)
            } catch {
                print("⚠️ [Humango Health] WorkoutScheduler requestAuthorization failed: \(error)")
                throw error
            }
        case .authorized:
            return authorizationStatusMap(from: authState)
        case .denied:
            return authorizationStatusMap(from: authState)
        @unknown default:
            return ["status": "unknown", "authorized": false]
        }
    }
    
    @available(iOS 17.0, *)
    private func authorizationStatusMap(from state: WorkoutScheduler.AuthorizationState) -> [String: Any] {
        switch state {
        case .notDetermined:
            return ["status": "notDetermined", "authorized": false]
        case .authorized:
            return ["status": "authorized", "authorized": true]
        case .denied:
            return ["status": "denied", "authorized": false]
        @unknown default:
            return ["status": "unknown", "authorized": false]
        }
    }

    // MARK: - Core Scheduling Logic

    @available(iOS 17.4, *)
    func scheduleWorkouts(jsonArray: [[String: Any]]) async throws -> [[String: Any]] {
        
        // MARK: - Strict Validation (All or Nothing)
        // Validate ALL workouts first - if ANY fails, reject the entire batch
        var validationErrors: [[String: Any]] = []
        
        for (index, dict) in jsonArray.enumerated() {
            var errors: [String] = []
            
            // 1. Validate schedule_id (REQUIRED)
            let hasScheduleId = dict["schedule_id"] != nil
            if !hasScheduleId {
                errors.append("Missing required field: 'schedule_id'")
            }
            
            // 2. Validate date (REQUIRED)
            let dateStr = dict["date"] as? String
            if dateStr == nil {
                errors.append("Missing required field: 'date'")
            } else if DateUtils.parseDate(from: dateStr!) == nil {
                errors.append("Invalid date format: '\(dateStr!)'. Expected ISO8601 format.")
            }
            
            // 3. Validate blocks (REQUIRED and non-empty)
            if let blocks = dict["blocks"] as? [[String: Any]] {
                if blocks.isEmpty {
                    errors.append("'blocks' array cannot be empty")
                }
            } else {
                errors.append("Missing required field: 'blocks' (must be a non-empty array)")
            }
            
            if !errors.isEmpty {
                validationErrors.append([
                    "index": index,
                    "schedule_id": dict["schedule_id"] ?? "N/A",
                    "errors": errors,
                    "failedJson": dict
                ])
            }
        }
        
        // If ANY validation errors exist, reject the ENTIRE batch
        if !validationErrors.isEmpty {
            let errorDetails = validationErrors.map { error -> String in
                let idx = error["index"] as? Int ?? -1
                let scheduleId = error["schedule_id"] ?? "N/A"
                let errs = error["errors"] as? [String] ?? []
                return "Workout[\(idx)] (schedule_id: \(scheduleId)): \(errs.joined(separator: ", "))"
            }.joined(separator: "; ")
            
            print("❌ [Humango Health] Validation failed for \(validationErrors.count) workout(s): \(errorDetails)")
            
            throw NSError(domain: "WorkoutValidation", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Validation failed: \(errorDetails)",
                "validationErrors": validationErrors
            ])
        }
        
        // All workouts passed validation, continue with processing
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]
        
        // Fallback for Flutter's local toIso8601String() which omits timezone 'Z'
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let fallbackFormatterNoFrac = DateFormatter()
        fallbackFormatterNoFrac.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatterNoFrac.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let now = Date()
        let sevenDaysFromNow = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        
        var validJsonArray: [[String: Any]] = []
        var skippedRecords: [[String: Any]] = []

        // 2. Date Range Filtering + Deduplication Check (validation already passed)
        for dict in jsonArray {
            let dateStr = dict["date"] as! String
            let workoutDate = DateUtils.parseDate(from: dateStr)!
            
            if workoutDate > now && workoutDate <= sevenDaysFromNow {
                // Check deduplication using JSON bytes comparison
                if let workoutId = store.extractWorkoutId(from: dict) {
                    let (needsPush, reason) = store.checkDeduplication(workoutId: workoutId, jsonDict: dict)
                    if needsPush {
                        validJsonArray.append(dict)
                        print("📤 [Humango Health] Workout \(workoutId) will be scheduled (reason: \(reason))")
                    } else {
                        // Already exists with same content, skip - include both JSONs for comparison
                        var skippedRecord: [String: Any] = [
                            "workoutId": workoutId,
                            "status": "skipped",
                            "reason": reason,
                            "currentJson": dict  // The JSON being pushed now
                        ]
                        
                        // Include existing JSON from store
                        if let existingRecord = store.getRecord(for: workoutId) {
                            let existingJsonDict = existingRecord.workoutJson.mapValues { $0.value }
                            skippedRecord["existingJson"] = existingJsonDict
                            skippedRecord["existingJsonSizeBytes"] = existingRecord.jsonBytes.count
                            skippedRecord["workoutPlanId"] = existingRecord.workoutPlanId
                        }
                        
                        // Calculate current JSON size
                        if let currentJsonBytes = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys) {
                            skippedRecord["currentJsonSizeBytes"] = currentJsonBytes.count
                        }
                        
                        skippedRecords.append(skippedRecord)
                        print("⏭️ [Humango Health] Skipping workout \(workoutId) — \(reason)")
                    }
                } else {
                    // This should never happen since validation requires schedule_id
                    // But just in case, throw an error
                    throw NSError(domain: "WorkoutValidation", code: 400, userInfo: [
                        NSLocalizedDescriptionKey: "Internal error: workout passed validation but has no schedule_id"
                    ])
                }
            } else {
                 // Date outside 7-day window - this is also a validation failure
                 throw NSError(domain: "WorkoutValidation", code: 400, userInfo: [
                     NSLocalizedDescriptionKey: "Workout date '\(dateStr)' is outside the valid 7-day scheduling window (must be in the future and within 7 days)"
                 ])
            }
        }

        print("ValidJsonArray (after dedup): \(validJsonArray.count), Skipped: \(skippedRecords.count)")
        
        
        guard !validJsonArray.isEmpty else { return skippedRecords }

        // 2. Decode into Models using the provided User schema
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let jsonData = try JSONSerialization.data(withJSONObject: validJsonArray, options: [])
        print("jsonData \(jsonData)")
        let instanceModels = try decoder.decode([WorkoutInstanceModelElement].self, from: jsonData)

        // 3. Build native WorkoutKit items using reference Builder logic
        let items: [ScheduledWorkoutItem]
        do {
            items = try builder.createCustomWorkouts(workouts: instanceModels)
        } catch {
            throw NSError(domain: "PlanManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Builder failed: \(error.localizedDescription)"
            ])
        }
        
        // 3.5 Check and Request WorkoutKit specific Authorization
        if #available(iOS 17.0, *) {
            let authState = await WorkoutScheduler.shared.authorizationState
            if authState == .notDetermined {
                do {
                    try await WorkoutScheduler.shared.requestAuthorization()
                } catch {
                    print("⚠️ [Humango Health] WorkoutScheduler requestAuthorization failed: \(error)")
                }
            } else if authState == .denied {
                throw NSError(domain: "WorkoutKit", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "WorkoutKit authorization was denied. Please go to Settings -> Health -> Data Access to permit Workout scheduling."
                ])
            }
        }

        var returnRecords: [[String: Any]] = []

        // 4. Schedule each via WorkoutScheduler
        for (index, item) in items.enumerated() {
            let workoutPlanNative = WorkoutPlan(item.workout)
            let workoutPlanId = workoutPlanNative.id.uuidString
            print("✅ WorkoutPlan id : \(workoutPlanId)")
            let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.scheduledDate)
            let scheduledWorkout = ScheduledWorkoutPlan(workoutPlanNative, date: dateComponents)
            
            if #available(iOS 17.0, *) {
                // Check if we hit the limit
                if await WorkoutScheduler.shared.scheduledWorkouts.count >= WorkoutScheduler.maxAllowedScheduledWorkoutCount {
                    print("⚠️ [Humango Health] Reached maximum allowed scheduled workouts. Stopping.")
                    break
                }
                
                await WorkoutScheduler.shared.schedule(scheduledWorkout.plan, at: scheduledWorkout.date)
                
                // Safe name extraction wrapper from reference
                let name = item.workoutModel.summary?.name ?? "Unnamed Work"
                print("✅ [Humango Health] Natively Scheduled '\(name)' | PlanId: \(workoutPlanId)")
            }

            // 5. Save record with WorkoutPlan ID
            let fullJsonDict = validJsonArray[index] // Re-grab original JSON
            if let workoutId = store.extractWorkoutId(from: fullJsonDict) {
                store.saveRecord(
                    workoutId: workoutId,
                    workoutPlanId: workoutPlanId,
                    jsonDict: fullJsonDict,
                    scheduledDate: item.scheduledDate
                )
                
                let jsonBytes = try JSONSerialization.data(withJSONObject: fullJsonDict, options: []).count
                
                returnRecords.append([
                    "workoutId": workoutId,
                    "workoutPlanId": workoutPlanId,
                    "scheduledDateTime": fullJsonDict["date"],
                    "jsonSizeBytes": jsonBytes,
                    "status": "scheduled",
                    "pushedAt": isoFormatter.string(from: Date()),
                    "workoutJson": fullJsonDict  // Include the full JSON in response
                ])
            }
        }
        
        // Include skipped records in the response
        returnRecords.append(contentsOf: skippedRecords)
        
        return returnRecords
    }
}
