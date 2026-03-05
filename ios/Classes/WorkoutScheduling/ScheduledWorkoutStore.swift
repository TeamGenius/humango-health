//
//  ScheduledWorkoutStore.swift
//  humango_health
//

import Foundation
import HealthKit

// MARK: - Record Model

struct ScheduledWorkoutRecord: Codable {
    let workoutId: String
    let workoutPlanId: String
    let workoutJson: [String: AnyCodable]
    let jsonBytes: Data
    let scheduledDate: Date
}

// MARK: - AnyCodable Wrapper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intVal = value as? Int {
            try container.encode(intVal)
        } else if let doubleVal = value as? Double {
            try container.encode(doubleVal)
        } else if let boolVal = value as? Bool {
            try container.encode(boolVal)
        } else if let stringVal = value as? String {
            try container.encode(stringVal)
        } else if let arrayVal = value as? [Any] {
            try container.encode(arrayVal.map { AnyCodable($0) })
        } else if let dictVal = value as? [String: Any] {
            try container.encode(dictVal.mapValues { AnyCodable($0) })
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - Scheduled Workout Store

class ScheduledWorkoutStore {
    static let shared = ScheduledWorkoutStore()

    private var records: [String: ScheduledWorkoutRecord] = [:]
    private let storageKey = "com.humango_health.scheduledWorkoutRecords"

    private init() {
        loadFromDisk()
    }

    // MARK: - CRUD Operations

    /// Save a workout record after scheduling natively.
    func saveRecord(
        workoutId: String,
        workoutPlanId: String,
        jsonDict: [String: Any],
        scheduledDate: Date
    ) {
        let codableDict = jsonDict.mapValues { AnyCodable($0) }
        // Use sortedKeys for consistent byte comparison in deduplication
        let jsonBytes = (try? JSONSerialization.data(withJSONObject: jsonDict, options: .sortedKeys)) ?? Data()

        let record = ScheduledWorkoutRecord(
            workoutId: workoutId,
            workoutPlanId: workoutPlanId,
            workoutJson: codableDict,
            jsonBytes: jsonBytes,
            scheduledDate: scheduledDate
        )

        records[workoutId] = record
        saveToDisk()
        print("💾 [Humango Health] Saved record for workout ID: \(workoutId), planId: \(workoutPlanId), bytes: \(jsonBytes.count)")
    }

    func getRecord(for workoutId: String) -> ScheduledWorkoutRecord? {
        return records[workoutId]
    }

    func getAllRecords() -> [String: ScheduledWorkoutRecord] {
        return records
    }

    @discardableResult
    func removeRecord(for workoutId: String) -> ScheduledWorkoutRecord? {
        let removed = records.removeValue(forKey: workoutId)
        if removed != nil {
            saveToDisk()
            print("🗑️ [Humango Health] Removed native record for workout ID: \(workoutId)")
        }
        return removed
    }

    func removeCompletedWorkouts() -> [String] {
        let now = Date()
        let completedIds = records.filter { $0.value.scheduledDate <= now }.map { $0.key }

        for id in completedIds {
            records.removeValue(forKey: id)
        }

        if !completedIds.isEmpty {
            saveToDisk()
            print("🗑️ [Humango Health] Removed \(completedIds.count) completed native workout records")
        }
        return completedIds
    }

    func clearAll() {
        records.removeAll()
        saveToDisk()
        print("🗑️ [Humango Health] Cleared all native workout records")
    }

    func extractWorkoutId(from jsonDict: [String: Any]) -> String? {
        if let id = jsonDict["schedule_id"] as? String {
            return id
        } else if let id = jsonDict["schedule_id"] as? Int {
            return String(id)
        } else if let id = jsonDict["id"] as? String {
            return id
        } else if let id = jsonDict["id"] as? Int {
            return String(id)
        } else if let id = jsonDict["workout_id"] as? String {
            return id
        } else if let id = jsonDict["workout_id"] as? Int {
            return String(id)
        }
        return nil
    }
    
    // MARK: - Workout Matching
    
    /// Find scheduled workout by WorkoutPlan ID (UUID)
    /// This is the most reliable matching method for iOS 17.0+
    func findWorkoutByPlanId(_ planId: String) -> String? {
        for (workoutId, record) in records {
            if record.workoutPlanId == planId {
                debugPrint("🎯 ScheduledWorkoutStore: Found workout \(workoutId) by planId \(planId)")
                return workoutId
            }
        }
        debugPrint("⚠️ ScheduledWorkoutStore: No workout found for planId \(planId)")
        return nil
    }
    
    /// Get the WorkoutPlan ID for a given workout ID (schedule_id)
    func getPlanId(for workoutId: String) -> String? {
        return records[workoutId]?.workoutPlanId
    }
    
    // MARK: - Deduplication
    
    /// Check if a workout needs to be pushed based on JSON byte comparison.
    /// Returns a tuple: (needsPush: Bool, reason: String)
    /// - If workout doesn't exist: needsPush = true, reason = "new"
    /// - If JSON bytes changed: needsPush = true, reason = "modified"
    /// - If JSON bytes are identical: needsPush = false, reason = "unchanged"
    func checkDeduplication(workoutId: String, jsonDict: [String: Any]) -> (needsPush: Bool, reason: String) {
        guard let existingRecord = records[workoutId] else {
            return (true, "new")
        }
        
        // Calculate JSON bytes for the incoming workout
        guard let incomingJsonBytes = try? JSONSerialization.data(withJSONObject: jsonDict, options: .sortedKeys) else {
            // If we can't serialize, assume it needs push
            return (true, "serialization_error")
        }
        
        // Re-serialize the existing JSON for fair comparison (with sorted keys)
        let existingDict = existingRecord.workoutJson.mapValues { $0.value }
        guard let existingJsonBytes = try? JSONSerialization.data(withJSONObject: existingDict, options: .sortedKeys) else {
            // If existing can't be serialized, push the new one
            return (true, "existing_serialization_error")
        }
        
        // Compare byte sizes first (fast check)
        if incomingJsonBytes.count != existingJsonBytes.count {
            print("📊 [Humango Health] Dedup: Workout \(workoutId) size changed (\(existingJsonBytes.count) → \(incomingJsonBytes.count) bytes)")
            return (true, "size_changed")
        }
        
        // Compare actual bytes (content check)
        if incomingJsonBytes != existingJsonBytes {
            print("📊 [Humango Health] Dedup: Workout \(workoutId) content changed (same size: \(incomingJsonBytes.count) bytes)")
            return (true, "content_changed")
        }
        
        print("⏭️ [Humango Health] Dedup: Workout \(workoutId) unchanged (\(incomingJsonBytes.count) bytes)")
        return (false, "unchanged")
    }
    
    /// Get the stored JSON byte size for a workout
    func getJsonBytesSize(for workoutId: String) -> Int? {
        return records[workoutId]?.jsonBytes.count
    }
    
    /// Find the scheduled workout that matches a completed workout
    /// Returns the workout ID (schedule_id) if found, nil otherwise
    /// Matches by date (within 10 minutes) and activity type
    func findMatchingScheduledWorkout(startDate: Date, activityType: HKWorkoutActivityType) -> String? {
        let tolerance: TimeInterval = 10 * 60 // 10 minutes
        
        var bestMatch: (id: String, timeDiff: TimeInterval)? = nil
        
        for (workoutId, record) in records {
            let timeDifference = abs(record.scheduledDate.timeIntervalSince(startDate))
            
            // Check if dates match within tolerance
            if timeDifference <= tolerance {
                // Try to extract activity type from JSON
                var typeMatches = false
                
                if let activityName = record.workoutJson["summary"]?.value as? [String: Any],
                   let sportType = activityName["name"] as? String {
                    // Name matching
                    let activityTypeName = activityType.name.lowercased()
                    typeMatches = sportType.lowercased().contains(activityTypeName) || 
                                 activityTypeName.contains(sportType.lowercased())
                } else {
                    // If we can't extract sport type, match by time only
                    typeMatches = true
                }
                
                if typeMatches {
                    // Keep the closest time match
                    if bestMatch == nil || timeDifference < bestMatch!.timeDiff {
                        bestMatch = (workoutId, timeDifference)
                    }
                }
            }
        }
        
        return bestMatch?.id
    }
    
    /// Check if a completed workout matches any scheduled workout
    func isWorkoutScheduled(startDate: Date, activityType: HKWorkoutActivityType) -> Bool {
        return findMatchingScheduledWorkout(startDate: startDate, activityType: activityType) != nil
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([String: ScheduledWorkoutRecord].self, from: data) {
            records = loaded
            print("📂 [Humango Health] Loaded \(loaded.count) native records from disk")
        }
    }
}
