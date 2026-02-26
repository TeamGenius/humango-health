//
// WorkoutRecordStore.swift
// Simple UserDefaults-backed store for tracking workouts to push
//
// Usage: await WorkoutRecordStore.shared.shouldPush(deviceActivityId:payload)
//

import Foundation
import CryptoKit

@available(iOS 13.0, *)
actor WorkoutRecordStore {
    static let shared = WorkoutRecordStore()

    private struct Record: Codable {
        var deviceActivityId: String
        var dataHash: String
        var dataSize: Int
        var pushed: Bool
        var firstSeenISO: String?
        var lastUpdatedISO: String
    }

    // UserDefaults key
    private let defaultsKey = "WorkoutRecordStore.records.v1"

    // in-memory cache (actor-isolated)
    private var recordsById: [String: Record] = [:]

    // date formatter
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        loadFromDefaults()
    }

    // MARK: - Persistence (UserDefaults)
    private func loadFromDefaults() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            recordsById = [:]
            return
        }
        do {
            let arr = try JSONDecoder().decode([Record].self, from: data)
            recordsById = Dictionary(uniqueKeysWithValues: arr.map { ($0.deviceActivityId, $0) })
        } catch {
            debugPrint("WorkoutRecordStore: loadFromDefaults failed:", error)
            recordsById = [:]
        }
    }

    private func saveToDefaults() {
        do {
            let arr = Array(recordsById.values)
            let data = try JSONEncoder().encode(arr)
            UserDefaults.standard.set(data, forKey: defaultsKey)
            // ensure immediate write (optional)
            UserDefaults.standard.synchronize()
        } catch {
            debugPrint("WorkoutRecordStore: saveToDefaults failed:", error)
        }
    }

    // MARK: - helpers
    private func isoString(_ date: Date = Date()) -> String {
        return isoFormatter.string(from: date)
    }

    private func sha256Hex(_ data: Data) -> String {
        let h = SHA256.hash(data: data)
        return h.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public API (async)

    /// Return true if we should push the given payload for deviceActivityId.
    /// Push if: no record exists OR pushed==false OR hash changed OR size changed.
    func shouldPush(deviceActivityId: String, payload: Data) async -> Bool {
        let hash = sha256Hex(payload)
        let size = payload.count

        if let rec = recordsById[deviceActivityId] {
            if rec.pushed == false { return true }
            if rec.dataSize != size { return true }   // covers appended route data
            return false
        } else {
            return true
        }
    }

    /// Insert or update record with pushed=false and payload hash + size.
    func upsertRecordPending(deviceActivityId: String, payload: Data) async {
        let hash = sha256Hex(payload)
        let size = payload.count
        let nowISO = isoString()

        if var rec = recordsById[deviceActivityId] {
            rec.dataHash = hash
            rec.dataSize = size
            rec.pushed = false
            rec.lastUpdatedISO = nowISO
            recordsById[deviceActivityId] = rec
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             dataHash: hash,
                             dataSize: size,
                             pushed: false,
                             firstSeenISO: nowISO,
                             lastUpdatedISO: nowISO)
            recordsById[deviceActivityId] = rec
        }
        saveToDefaults()
    }

    /// Mark a record as pushed = true (creates the record if absent; leaves dataHash empty)
    func markPushed(deviceActivityId: String) async {
        let nowISO = isoString()
        if var rec = recordsById[deviceActivityId] {
            rec.pushed = true
            rec.lastUpdatedISO = nowISO
            recordsById[deviceActivityId] = rec
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             dataHash: "",
                             dataSize: 0,
                             pushed: true,
                             firstSeenISO: nowISO,
                             lastUpdatedISO: nowISO)
            recordsById[deviceActivityId] = rec
        }
        saveToDefaults()
    }

    /// Update data hash & size and mark pushed=false
    func updateDataHash(deviceActivityId: String, payload: Data) async {
        let hash = sha256Hex(payload)
        let size = payload.count
        let nowISO = isoString()
        if var rec = recordsById[deviceActivityId] {
            rec.dataHash = hash
            rec.dataSize = size
            rec.pushed = false
            rec.lastUpdatedISO = nowISO
            recordsById[deviceActivityId] = rec
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             dataHash: hash,
                             dataSize: size,
                             pushed: false,
                             firstSeenISO: nowISO,
                             lastUpdatedISO: nowISO)
            recordsById[deviceActivityId] = rec
        }
        saveToDefaults()
    }

    /// Return true if a record exists locally
    func hasRecord(deviceActivityId: String) async -> Bool {
        return recordsById[deviceActivityId] != nil
    }

    /// Record the firstSeen time (idempotent)
    func recordFirstSeen(deviceActivityId: String, date: Date = Date()) async {
        let iso = isoString(date)
        if var rec = recordsById[deviceActivityId] {
            if rec.firstSeenISO == nil {
                rec.firstSeenISO = iso
                rec.lastUpdatedISO = iso
                recordsById[deviceActivityId] = rec
                saveToDefaults()
            }
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             dataHash: "",
                             dataSize: 0,
                             pushed: false,
                             firstSeenISO: iso,
                             lastUpdatedISO: iso)
            recordsById[deviceActivityId] = rec
            saveToDefaults()
        }
    }

    /// Update lastSeen timestamp (touch)
    func updateLastSeen(deviceActivityId: String, date: Date = Date()) async {
        let iso = isoString(date)
        if var rec = recordsById[deviceActivityId] {
            rec.lastUpdatedISO = iso
            recordsById[deviceActivityId] = rec
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             dataHash: "",
                             dataSize: 0,
                             pushed: false,
                             firstSeenISO: iso,
                             lastUpdatedISO: iso)
            recordsById[deviceActivityId] = rec
        }
        saveToDefaults()
    }

    /// Remove records older than `days` (default 15)
    func cleanupOlderThan(days: Int = 15) async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let cutoffISO = isoString(cutoff)
        recordsById = recordsById.filter { $0.value.lastUpdatedISO >= cutoffISO }
        saveToDefaults()
    }

    /// For debug: return all records as dictionaries
    func fetchAllRecords() async -> [[String: Any]] {
        return recordsById.values.map { rec in
            return [
                "deviceActivityId": rec.deviceActivityId,
                "dataHash": rec.dataHash,
                "dataSize": rec.dataSize,
                "pushed": rec.pushed,
                "firstSeenISO": rec.firstSeenISO as Any,
                "lastUpdatedISO": rec.lastUpdatedISO
            ]
        }
    }

    /// Optional: remove a specific record
    func removeRecord(deviceActivityId: String) async {
        recordsById.removeValue(forKey: deviceActivityId)
        saveToDefaults()
    }

    /// Optional: clear all records
    func clearAll() async {
        recordsById.removeAll()
        saveToDefaults()
    }
}


