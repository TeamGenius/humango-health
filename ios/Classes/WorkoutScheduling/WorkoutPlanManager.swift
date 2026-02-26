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
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Core Scheduling Logic

    @available(iOS 17.4, *)
    func scheduleWorkouts(jsonArray: [[String: Any]]) async throws -> [[String: Any]] {
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

        // 1. Initial Filtering
        for dict in jsonArray {
            guard let dateStr = dict["date"] as? String,
                  let workoutDate = DateUtils.parseDate(from: dateStr) else {
                print("⚠️ [Humango Health] Skipping workout with invalid date formatting: \(dict["date"] ?? "nil")")
                continue
            }
            
            if workoutDate > now && workoutDate <= sevenDaysFromNow {
                validJsonArray.append(dict)
            } else {
                 print("⏭️ [Humango Health] Skipping native schedule — Date \(dateStr) is outside the 7 day Window.")
            }
        }

        print("ValidJsonArray \(validJsonArray)")
        
        
        guard !validJsonArray.isEmpty else { return [] }

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
            
            let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.scheduledDate)
            let scheduledWorkout = ScheduledWorkoutPlan(workoutPlanNative, date: dateComponents)
            var hashValue: Int = 0
            
            if #available(iOS 17.0, *) {
                // Check if we hit the limit
                if await WorkoutScheduler.shared.scheduledWorkouts.count >= WorkoutScheduler.maxAllowedScheduledWorkoutCount {
                    print("⚠️ [Humango Health] Reached maximum allowed scheduled workouts. Stopping.")
                    break
                }
                
                await WorkoutScheduler.shared.schedule(scheduledWorkout.plan, at: scheduledWorkout.date)
                hashValue = scheduledWorkout.hashValue
                
                // Safe name extraction wrapper from reference
                let name = item.workoutModel.summary?.name ?? "Unnamed Work"
                print("✅ [Humango Health] Natively Scheduled '\(name)' | Hash: \(hashValue)")
            }

            // 5. Save Deduplication Hash
            let fullJsonDict = validJsonArray[index] // Re-grab original JSON
            if let workoutId = store.extractWorkoutId(from: fullJsonDict) {
                store.saveRecord(
                    workoutId: workoutId,
                    jsonDict: fullJsonDict,
                    hashValue: hashValue,
                    scheduledDate: item.scheduledDate
                )
                
                let jsonBytes = try JSONSerialization.data(withJSONObject: fullJsonDict, options: []).count
                
                returnRecords.append([
                    "workoutId": workoutId,
                    "scheduledDateTime": fullJsonDict["date"],
                    "hashValue": String(hashValue),
                    "jsonSizeBytes": jsonBytes,
                    "pushedAt": isoFormatter.string(from: Date())
                ])
            }
        }
        
        return returnRecords
    }
}
