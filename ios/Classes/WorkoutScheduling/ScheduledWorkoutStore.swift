//
//  ScheduledWorkoutStore.swift
//  humango_health
//

import Foundation
import HealthKit
import CryptoKit

// MARK: - Record Model

struct ScheduledWorkoutRecord: Codable {
    let scheduleId: String        // schedule_id from JSON (UUID e.g. "8de52c5d-...")
    let workoutId: String         // workout_id from JSON (e.g. "232550")
    let workoutPlanId: String     // Apple WorkoutKit plan UUID
    let workoutJson: [String: AnyCodable]
    let jsonHash: String          // SHA-256 hex of sorted-key JSON bytes
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
        scheduleId: String,
        workoutId: String,
        workoutPlanId: String,
        jsonDict: [String: Any],
        scheduledDate: Date
    ) {
        let codableDict = jsonDict.mapValues { AnyCodable($0) }
        let jsonBytes = (try? JSONSerialization.data(withJSONObject: jsonDict, options: .sortedKeys)) ?? Data()
        let jsonHash = sha256Hash(of: jsonBytes)

        let record = ScheduledWorkoutRecord(
            scheduleId: scheduleId,
            workoutId: workoutId,
            workoutPlanId: workoutPlanId,
            workoutJson: codableDict,
            jsonHash: jsonHash,
            scheduledDate: scheduledDate
        )

        records[scheduleId] = record
        saveToDisk()
        print("💾 [Humango Health] Saved record — scheduleId: \(scheduleId), workoutId: \(workoutId), planId: \(workoutPlanId), hash: \(jsonHash)")
    }

    func getRecord(forScheduleId scheduleId: String) -> ScheduledWorkoutRecord? {
        return records[scheduleId]
    }

    func getAllRecords() -> [String: ScheduledWorkoutRecord] {
        return records
    }

    @discardableResult
    func removeRecord(forScheduleId scheduleId: String) -> ScheduledWorkoutRecord? {
        let removed = records.removeValue(forKey: scheduleId)
        if removed != nil {
            saveToDisk()
            print("🗑️ [Humango Health] Removed native record for scheduleId: \(scheduleId)")
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

    func extractScheduleId(from jsonDict: [String: Any]) -> String? {
        if let id = jsonDict["schedule_id"] as? String {
            return id
        } else if let id = jsonDict["schedule_id"] as? Int {
            return String(id)
        }
        return nil
    }

    func extractWorkoutId(from jsonDict: [String: Any]) -> String? {
        if let id = jsonDict["workout_id"] as? String {
            return id
        } else if let id = jsonDict["workout_id"] as? Int {
            return String(id)
        }
        return nil
    }
    
    // MARK: - Workout Matching
    
    /// Find scheduleId by WorkoutPlan ID (UUID)
    /// This is the most reliable matching method for iOS 17.0+
    func findWorkoutByPlanId(_ planId: String) -> String? {
        for (scheduleId, record) in records {
            if record.workoutPlanId == planId {
                debugPrint("🎯 ScheduledWorkoutStore: Found scheduleId \(scheduleId) by planId \(planId)")
                return scheduleId
            }
        }
        debugPrint("⚠️ ScheduledWorkoutStore: No schedule found for planId \(planId)")
        return nil
    }
    
    /// Get the WorkoutPlan ID for a given scheduleId (schedule_id)
    func getPlanId(forScheduleId scheduleId: String) -> String? {
        return records[scheduleId]?.workoutPlanId
    }
    
    // MARK: - Deduplication

    // MARK: - SHA-256 Helpers

    /// Computes SHA-256 hex string of raw data.
    private func sha256Hash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Serialises a JSON dictionary (sorted keys) and returns its SHA-256 hex.
    /// Returns nil if serialisation fails.
    func computeJsonHash(for jsonDict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonDict, options: .sortedKeys) else {
            return nil
        }
        return sha256Hash(of: data)
    }

    // MARK: - Deduplication Check

    /// Determines whether a workout needs to be re-pushed.
    ///
    /// The check is performed in two stages:
    ///   1. **Date comparison** – if the incoming `scheduledDate` differs from the stored one
    ///      (compared at second precision), the workout is considered modified.
    ///   2. **SHA-256 hash comparison** – the SHA-256 of the sorted-key JSON serialisation is
    ///      compared with the stored hash.  A mismatch means the content changed.
    ///
    /// Returns `(needsPush: Bool, reason: String)` where `reason` is one of:
    ///   `"new"`, `"date_changed"`, `"content_changed"`, `"unchanged"`, `"serialization_error"`
    func checkDeduplication(
        scheduleId: String,
        jsonDict: [String: Any],
        scheduledDate: Date
    ) -> (needsPush: Bool, reason: String) {
        guard let existingRecord = records[scheduleId] else {
            return (true, "new")
        }

        // 1. Compare scheduled date (second precision — ISO8601 dates have no sub-second resolution)
        let existingSeconds = Int(existingRecord.scheduledDate.timeIntervalSince1970)
        let incomingSeconds = Int(scheduledDate.timeIntervalSince1970)
        if existingSeconds != incomingSeconds {
            let existingStr = ISO8601DateFormatter().string(from: existingRecord.scheduledDate)
            let incomingStr = ISO8601DateFormatter().string(from: scheduledDate)
            print("📅 [Humango Health] Dedup: Schedule \(scheduleId) date changed (\(existingStr) → \(incomingStr))")
            return (true, "date_changed")
        }

        // 2. Compute SHA-256 of the incoming JSON
        guard let incomingJsonBytes = try? JSONSerialization.data(withJSONObject: jsonDict, options: .sortedKeys) else {
            return (true, "serialization_error")
        }
        let incomingHash = sha256Hash(of: incomingJsonBytes)

        // 3. Compare hashes
        if incomingHash != existingRecord.jsonHash {
            print("📊 [Humango Health] Dedup: Schedule \(scheduleId) content changed (hash mismatch: \(existingRecord.jsonHash) → \(incomingHash))")
            return (true, "content_changed")
        }

        print("⏭️ [Humango Health] Dedup: Schedule \(scheduleId) unchanged (hash: \(incomingHash))")
        return (false, "unchanged")
    }

    /// Returns the stored SHA-256 hash for a schedule ID.
    func getJsonHash(forScheduleId scheduleId: String) -> String? {
        return records[scheduleId]?.jsonHash
    }
    
    /// Find the scheduled workout that matches a completed workout
    /// Returns the scheduleId (schedule_id value) if found, nil otherwise
    /// Matches by date (within 10 minutes) and activity type
    func findMatchingScheduledWorkout(startDate: Date, activityType: HKWorkoutActivityType) -> String? {
        let tolerance: TimeInterval = 10 * 60 // 10 minutes
        
        var bestMatch: (id: String, timeDiff: TimeInterval)? = nil
        
        for (scheduleId, record) in records {
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
                        bestMatch = (scheduleId, timeDifference)
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
