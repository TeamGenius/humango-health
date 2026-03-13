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
        case "computeWorkoutJsonHash":
            guard let jsonDict = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected a JSON dictionary", details: nil))
                return
            }
            if let hash = ScheduledWorkoutStore.shared.computeJsonHash(for: jsonDict) {
                result(hash)
            } else {
                result(FlutterError(code: "HASH_ERROR", message: "Failed to serialize JSON for hashing", details: nil))
            }

        case "scheduleWorkoutsFromFlutter":
            guard let args = call.arguments as? [[String: Any]] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected array of workout dictionaries", details: nil))
                return
            }
            
            Task {
                do {
                    let scheduledRecords = try await scheduleWorkouts(jsonArray: args)
                    DispatchQueue.main.async {
                        result(["scheduledRecords": scheduledRecords])
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "SCHEDULE_ERROR", message: error.localizedDescription, details: nil))
                    }
                }
            }
            
        case "clearAppleScheduledWorkouts":
           store.clearAll()
           result(true)

        case "removeAllScheduledWorkouts":
            Task {
                let response = await self.removeAllScheduledWorkouts()
                DispatchQueue.main.async {
                    result(response)
                }
            }
            
        case "requestAuthorizationForWorkoutPush":
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
            
        case "getScheduledWorkouts":
            Task {
                let workouts = await self.getScheduledWorkouts()
                DispatchQueue.main.async {
                    result(workouts)
                }
            }
            
        case "removeScheduledWorkouts":
            guard let planIds = call.arguments as? [String], !planIds.isEmpty else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected a non-empty array of workoutPlanId strings", details: nil))
                return
            }
            
            Task {
                let response = await self.removeScheduledWorkouts(workoutPlanIds: planIds)
                DispatchQueue.main.async {
                    result(response)
                }
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Get Scheduled Workouts
    
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
            if let localScheduleId = store.findWorkoutByPlanId(planId) {
                workoutInfo["scheduleId"] = localScheduleId
                if let storedRecord = store.getRecord(forScheduleId: localScheduleId) {
                    workoutInfo["workoutId"] = storedRecord.workoutId
                    // Extract additional info from stored JSON
                    if let summary = storedRecord.workoutJson["summary"]?.value as? [String: Any],
                       let name = summary["name"] as? String {
                        workoutInfo["name"] = name
                    }
                    // Include the full stored JSON
                    let jsonDict = storedRecord.workoutJson.mapValues { $0.value }
                    workoutInfo["workoutJson"] = jsonDict
                    workoutInfo["jsonHash"] = storedRecord.jsonHash
                }
            }
            
            workoutsList.append(workoutInfo)
        }
        
        return workoutsList
    }
    
    // MARK: - Workout Push Authorization
    
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

    // MARK: - Remove All Scheduled Workouts

    /// Removes every scheduled workout from Apple Watch and clears the entire local store.
    private func removeAllScheduledWorkouts() async -> [String: Any] {
        let allScheduled = await WorkoutScheduler.shared.scheduledWorkouts
        var removedFromWatch = 0
        for sw in allScheduled {
            await WorkoutScheduler.shared.remove(sw.plan, at: sw.date)
            removedFromWatch += 1
            print("✅ [Humango Health] removeAll: removed planId \(sw.plan.id.uuidString) from Apple Watch")
        }
        let storeCount = store.getAllRecords().count
        store.clearAll()
        print("✅ [Humango Health] removeAll: cleared \(storeCount) local store records (watch removed: \(removedFromWatch))")
        return [
            "removedFromWatch": removedFromWatch,
            "storeCleared": true,
            "localRecordsCleared": storeCount,
        ]
    }

    // MARK: - Remove Scheduled Workouts

    /// Removes scheduled workouts from Apple Watch and local storage by their WorkoutPlan IDs.
    /// Returns a per-ID response indicating success or failure.
    private func removeScheduledWorkouts(workoutPlanIds: [String]) async -> [[String: Any]] {
        // Build a lookup: planId → ScheduledWorkoutPlan from the current Apple schedule
        let allScheduled = await WorkoutScheduler.shared.scheduledWorkouts
        var scheduledByPlanId: [String: ScheduledWorkoutPlan] = [:]
        for sw in allScheduled {
            scheduledByPlanId[sw.plan.id.uuidString] = sw
        }

        var results: [[String: Any]] = []

        for planId in workoutPlanIds {
            var entry: [String: Any] = ["workoutPlanId": planId]

            // 1. Find the matching workout on Apple Watch
            guard let scheduledWorkout = scheduledByPlanId[planId] else {
                // Not found in Apple's scheduler — still try to clean local storage
                let localScheduleId = store.findWorkoutByPlanId(planId)
                if let sId = localScheduleId {
                    let storedWorkoutId = store.getRecord(forScheduleId: sId)?.workoutId
                    store.removeRecord(forScheduleId: sId)
                    entry["scheduleId"] = sId
                    if let wId = storedWorkoutId { entry["workoutId"] = wId }
                    entry["status"] = "partial"
                    entry["message"] = "Not found on Apple Watch (may have already been completed or removed), but removed from local storage"
                    print("⚠️ [Humango Health] Remove: planId \(planId) not in Apple scheduler, local record for \(sId) removed")
                } else {
                    entry["status"] = "fail"
                    entry["message"] = "Not found on Apple Watch or in local storage"
                    print("❌ [Humango Health] Remove: planId \(planId) not found anywhere")
                }
                results.append(entry)
                continue
            }

            // 2. Remove from Apple Watch
            await WorkoutScheduler.shared.remove(scheduledWorkout.plan, at: scheduledWorkout.date)
            print("✅ [Humango Health] Removed planId \(planId) from Apple Watch")

            // 3. Remove from local storage
            if let localScheduleId = store.findWorkoutByPlanId(planId) {
                let storedWorkoutId = store.getRecord(forScheduleId: localScheduleId)?.workoutId
                store.removeRecord(forScheduleId: localScheduleId)
                entry["scheduleId"] = localScheduleId
                if let wId = storedWorkoutId { entry["workoutId"] = wId }
                print("✅ [Humango Health] Removed local record for scheduleId \(localScheduleId) (planId \(planId))")
            }

            entry["status"] = "success"
            entry["message"] = "Removed from Apple Watch and local storage"

            results.append(entry)
        }

        print("📋 [Humango Health] Remove results: \(results.count) items processed")
        return results
    }

    // MARK: - Core Scheduling Logic

    func scheduleWorkouts(jsonArray: [[String: Any]]) async throws -> [[String: Any]] {
        
        // Check if the current device supports scheduled workouts
        guard WorkoutScheduler.isSupported else {
            print("❌ [Humango Health] WorkoutScheduler.isSupported is false — device does not support scheduled workouts")
            return jsonArray.map { dict in
                let scheduleId = dict["schedule_id"] ?? "N/A"
                let workoutId = dict["workout_id"] ?? "N/A"
                return [
                    "scheduleId": "\(scheduleId)",
                    "workoutId": "\(workoutId)",
                    "status": "device_not_supported",
                    "reason": "This device does not support scheduled workouts (WorkoutScheduler.isSupported = false)",
                    "currentJson": dict
                ] as [String: Any]
            }
        }
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let now = Date()
        let sevenDaysFromNow = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        
        var validJsonArray: [[String: Any]] = []
        var skippedRecords: [[String: Any]] = []

        // 1. Per-workout validation + date range filtering + dedup — never reject the entire batch
        for (index, dict) in jsonArray.enumerated() {
            var errors: [String] = []
            
            // Validate schedule_id
            let hasScheduleId = dict["schedule_id"] != nil
            if !hasScheduleId {
                errors.append("Missing required field: 'schedule_id'")
            }
            
            // Validate date
            let dateStr = dict["date"] as? String
            var workoutDate: Date? = nil
            if dateStr == nil {
                errors.append("Missing required field: 'date'")
            } else if let parsed = DateUtils.parseDate(from: dateStr!) {
                workoutDate = parsed
            } else {
                errors.append("Invalid date format: '\(dateStr!)'. Expected ISO8601 format.")
            }
            
            // Validate blocks
            if let blocks = dict["blocks"] as? [[String: Any]] {
                if blocks.isEmpty {
                    errors.append("'blocks' array cannot be empty")
                }
            } else {
                errors.append("Missing required field: 'blocks' (must be a non-empty array)")
            }
            
            // If validation failed for this workout, record it as failed and continue
            if !errors.isEmpty {
                let scheduleId = dict["schedule_id"] ?? "N/A"
                let workoutId = dict["workout_id"] ?? "N/A"
                print("❌ [Humango Health] Validation failed for workout[\(index)] (schedule_id: \(scheduleId)): \(errors.joined(separator: ", "))")
                skippedRecords.append([
                    "scheduleId": "\(scheduleId)",
                    "workoutId": "\(workoutId)",
                    "status": "validation_error",
                    "reason": errors.joined(separator: "; "),
                    "currentJson": dict
                ])
                continue
            }
            
            // Date range check
            guard let date = workoutDate, date > now, date <= sevenDaysFromNow else {
                let scheduleId = dict["schedule_id"] ?? "N/A"
                let workoutId = dict["workout_id"] ?? "N/A"
                print("⏭️ [Humango Health] Schedule \(scheduleId) date outside 7-day window: \(dateStr ?? "nil")")
                skippedRecords.append([
                    "scheduleId": "\(scheduleId)",
                    "workoutId": "\(workoutId)",
                    "status": "skipped",
                    "reason": "date_outside_window",
                    "currentJson": dict
                ])
                continue
            }
            
            // Deduplication check
            if let scheduleId = store.extractScheduleId(from: dict) {
                let workoutId = store.extractWorkoutId(from: dict) ?? "N/A"
                let (needsPush, reason) = store.checkDeduplication(
                    scheduleId: scheduleId,
                    jsonDict: dict,
                    scheduledDate: date
                )
                if needsPush {
                    validJsonArray.append(dict)
                    print("📤 [Humango Health] Schedule \(scheduleId) will be scheduled (reason: \(reason))")
                } else {
                    var skippedRecord: [String: Any] = [
                        "scheduleId": scheduleId,
                        "workoutId": workoutId,
                        "status": "skipped",
                        "reason": reason,
                        "currentJson": dict
                    ]
                    if let existingRecord = store.getRecord(forScheduleId: scheduleId) {
                        let existingJsonDict = existingRecord.workoutJson.mapValues { $0.value }
                        skippedRecord["existingJson"] = existingJsonDict
                        skippedRecord["existingJsonHash"] = existingRecord.jsonHash
                        skippedRecord["workoutPlanId"] = existingRecord.workoutPlanId
                    }
                    skippedRecord["currentJsonHash"] = store.computeJsonHash(for: dict) ?? ""
                    skippedRecords.append(skippedRecord)
                    print("⏭️ [Humango Health] Skipping schedule \(scheduleId) — \(reason)")
                }
            } else {
                // Should never happen after validation, but handle gracefully
                skippedRecords.append([
                    "scheduleId": "N/A",
                    "workoutId": "N/A",
                    "status": "validation_error",
                    "reason": "Internal error: no schedule_id after validation",
                    "currentJson": dict
                ])
            }
        }

        print("ValidJsonArray (after dedup): \(validJsonArray.count), Skipped: \(skippedRecords.count)")
        
        guard !validJsonArray.isEmpty else { return skippedRecords }

        // 2. Decode into Models
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let jsonData = try JSONSerialization.data(withJSONObject: validJsonArray, options: [])
        print("jsonData \(jsonData)")
        let instanceModels = try decoder.decode([WorkoutInstanceModelElement].self, from: jsonData)

        // 3. Build native WorkoutKit items
        let items: [ScheduledWorkoutItem]
        do {
            items = try builder.createCustomWorkouts(workouts: instanceModels)
        } catch {
            throw NSError(domain: "PlanManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Builder failed: \(error.localizedDescription)"
            ])
        }
        
        // 3.5 Check and Request WorkoutKit Authorization
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

        var returnRecords: [[String: Any]] = []

        // Pre-fetch current Apple Watch schedule once (used for rescheduling lookups)
        var currentScheduledByPlanId: [String: ScheduledWorkoutPlan] = [:]
        for sw in await WorkoutScheduler.shared.scheduledWorkouts {
            currentScheduledByPlanId[sw.plan.id.uuidString] = sw
        }

        // 4. Schedule each via WorkoutScheduler
        for (index, item) in items.enumerated() {
            let fullJsonDict = validJsonArray[index]
            guard let scheduleId = store.extractScheduleId(from: fullJsonDict) else { continue }
            let workoutId = store.extractWorkoutId(from: fullJsonDict) ?? "N/A"
            
            // --- If this schedule already exists (rescheduling), remove the old one from Apple Watch first ---
            if let existingRecord = store.getRecord(forScheduleId: scheduleId) {
                let oldPlanId = existingRecord.workoutPlanId
                // Find the old scheduled workout on Apple Watch and remove it
                if let oldScheduled = currentScheduledByPlanId[oldPlanId] {
                    await WorkoutScheduler.shared.remove(oldScheduled.plan, at: oldScheduled.date)
                    currentScheduledByPlanId.removeValue(forKey: oldPlanId)
                    print("🔄 [Humango Health] Removed old schedule for \(scheduleId) (planId: \(oldPlanId)) before rescheduling")
                } else {
                    print("⚠️ [Humango Health] Old planId \(oldPlanId) for \(scheduleId) not found on Apple Watch (may have expired/completed)")
                }
                // Remove old local record (will be replaced below)
                store.removeRecord(forScheduleId: scheduleId)
            }
            
            let workoutPlanNative = WorkoutPlan(item.workout)
            let workoutPlanId = workoutPlanNative.id.uuidString
            print("✅ WorkoutPlan id : \(workoutPlanId)")
            let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.scheduledDate)
            let scheduledWorkout = ScheduledWorkoutPlan(workoutPlanNative, date: dateComponents)
            
            // Check if we hit the limit
            if await WorkoutScheduler.shared.scheduledWorkouts.count >= WorkoutScheduler.maxAllowedScheduledWorkoutCount {
                print("⚠️ [Humango Health] Reached maximum allowed scheduled workouts. Stopping.")
                break
            }
            
            await WorkoutScheduler.shared.schedule(scheduledWorkout.plan, at: scheduledWorkout.date)
            
            let name = item.workoutModel.summary?.name ?? "Unnamed Work"
            print("✅ [Humango Health] Natively Scheduled '\(name)' | PlanId: \(workoutPlanId)")

            // 5. Save record with WorkoutPlan ID
            store.saveRecord(
                scheduleId: scheduleId,
                workoutId: workoutId,
                workoutPlanId: workoutPlanId,
                jsonDict: fullJsonDict,
                scheduledDate: item.scheduledDate
            )
            
            let jsonHash = store.computeJsonHash(for: fullJsonDict) ?? ""
            
            returnRecords.append([
                "scheduleId": scheduleId,
                "workoutId": workoutId,
                "workoutPlanId": workoutPlanId,
                "scheduledDateTime": fullJsonDict["date"] as? String ?? "",
                "jsonHash": jsonHash,
                "status": "scheduled",
                "pushedAt": isoFormatter.string(from: Date()),
                "workoutJson": fullJsonDict
            ])
        }
        
        // Include skipped records in the response
        returnRecords.append(contentsOf: skippedRecords)
        
        return returnRecords
    }
}
