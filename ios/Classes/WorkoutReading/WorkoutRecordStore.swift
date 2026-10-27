//
// WorkoutRecordStore.swift
// Simple UserDefaults-backed store for tracking workouts to push.
// Moved from the HumanGO app's Runner; the UserDefaults key is unchanged so
// records saved by earlier app versions carry over.
//
// Deduplication key   : deviceActivityId (HKWorkout UUID)
// Change detector     : contentFingerprint — deterministic string built from
//                       duration, distance, sport, start_time, locationCount, sampleCount.
//                       Includes series_data counts so incremental route/sample
//                       delivery from HealthKit triggers a re-push.
//
// Usage: await WorkoutRecordStore.shared.shouldPush(deviceActivityId:contentFingerprint:)
//

import Foundation

@available(iOS 13.0, *)
public actor WorkoutRecordStore {
    public static let shared = WorkoutRecordStore()

    private struct Record: Codable {
        var deviceActivityId: String
        /// Deterministic fingerprint: "{duration}|{distance}|{sport}|{start_time}|{locationCount}|{sampleCount}"
        var contentFingerprint: String
        var pushed: Bool
        /// True while an API upload is in-flight for this workout.
        /// Prevents duplicate uploads when the same workout arrives again
        /// before the first upload completes.
        var callingApi: Bool
        var firstSeenISO: String?
        var lastUpdatedISO: String

        // Backward-compatible decoding: existing v4 records lack callingApi.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            deviceActivityId  = try c.decode(String.self, forKey: .deviceActivityId)
            contentFingerprint = try c.decode(String.self, forKey: .contentFingerprint)
            pushed            = try c.decode(Bool.self,   forKey: .pushed)
            callingApi        = try c.decodeIfPresent(Bool.self, forKey: .callingApi) ?? false
            firstSeenISO      = try c.decodeIfPresent(String.self, forKey: .firstSeenISO)
            lastUpdatedISO    = try c.decode(String.self, forKey: .lastUpdatedISO)
        }

        init(deviceActivityId: String, contentFingerprint: String, pushed: Bool, callingApi: Bool = false, firstSeenISO: String?, lastUpdatedISO: String) {
            self.deviceActivityId  = deviceActivityId
            self.contentFingerprint = contentFingerprint
            self.pushed            = pushed
            self.callingApi        = callingApi
            self.firstSeenISO      = firstSeenISO
            self.lastUpdatedISO    = lastUpdatedISO
        }
    }

    // UserDefaults key — v4 updates multisport fingerprint format
    private let defaultsKey = "WorkoutRecordStore.records.v4"

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

    // MARK: - Fingerprint

    /// Builds a deterministic fingerprint from stable workout dictionary fields.
    ///
    /// Single-sport format:
    ///   "{duration}|{distance}|{sport}|{start_time}|{locationCount}|{type1}:{count1},{type2}:{count2},..."
    ///
    /// Multisport format (detected by presence of "sessions" key):
    ///   "{device_activity_id}|{start_time}|{sessionCount}|{locationCount}|{type1}:{count1},{type2}:{count2},..."
    ///
    /// `series_data` is at the parent level for multisport workouts.
    /// locationCount comes from `series_data.locations`.
    /// Each sample group in `series_data.samples` is recorded as `type:seriesCount`
    /// (sorted alphabetically) so that incremental delivery triggers a re-push.
    ///
    /// Works with both `toDict()` output (keys: duration, distance, sport, start_time)
    /// and normalized/JSON-parsed dicts (keys: device_activity_id, etc.).
    public static func fingerprint(from dict: [String: Any]) -> String {
        let startTime = (dict["start_time"] as? String)
            ?? (dict["startTime"] as? String)
            ?? "n/a"

        // Multisport workouts have a "sessions" array at the top level
        // and no top-level duration/distance.
        if let sessions = dict["sessions"] as? [[String: Any]] {
            let deviceActivityId = (dict["device_activity_id"] as? String)
                ?? (dict["activity_id"] as? String)
                ?? "unknown"

            let sessionCount = sessions.count

            // series_data is at the parent level for multisport
            let seriesData = dict["series_data"] as? [String: Any]
            let locationCount = (seriesData?["locations"] as? [Any])?.count ?? 0

            // Build per-type sample counts: "type:count" sorted alphabetically
            let sampleBreakdown: String = {
                guard let groups = seriesData?["samples"] as? [[String: Any]] else { return "" }
                let pairs: [(String, Int)] = groups.compactMap { group in
                    guard let type = group["type"] as? String else { return nil }
                    let count = (group["series"] as? [Any])?.count ?? 0
                    return (type, count)
                }
                return pairs
                    .sorted { $0.0 < $1.0 }
                    .map { "\($0.0):\($0.1)" }
                    .joined(separator: ",")
            }()

            return "\(deviceActivityId)|\(startTime)|\(sessionCount)|\(locationCount)|\(sampleBreakdown)"
        }

        // Single-sport fingerprint
        let duration = (dict["duration"] as? Int)
            ?? (dict["duration"] as? Double).map { Int(round($0)) }
            ?? 0
        let distance = (dict["distance"] as? Int)
            ?? (dict["distance"] as? Double).map { Int(round($0)) }
            ?? 0
        let sport = (dict["sport"] as? String) ?? "unknown"

        // Route + sample counts from series_data
        let seriesData = dict["series_data"] as? [String: Any]
        let locationCount = (seriesData?["locations"] as? [Any])?.count ?? 0

        // Build per-type sample counts: "type:count" sorted alphabetically
        let sampleBreakdown: String = {
            guard let groups = seriesData?["samples"] as? [[String: Any]] else { return "" }
            let pairs: [(String, Int)] = groups.compactMap { group in
                guard let type = group["type"] as? String else { return nil }
                let count = (group["series"] as? [Any])?.count ?? 0
                return (type, count)
            }
            return pairs
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0):\($0.1)" }
                .joined(separator: ",")
        }()

        return "\(duration)|\(distance)|\(sport)|\(startTime)|\(locationCount)|\(sampleBreakdown)"
    }

    // MARK: - Public API (async)

    /// Return true if we should push the given workout for deviceActivityId.
    /// Push if: no record exists OR pushed==false OR fingerprint changed.
    public func shouldPush(deviceActivityId: String, contentFingerprint: String) async -> Bool {
        guard var rec = recordsById[deviceActivityId] else {
            debugPrint("WorkoutRecordStore.shouldPush: NO record found for deviceActivityId=\(deviceActivityId) → will push (new)")
            // Create a minimal record with callingApi=true so concurrent duplicates are dropped.
            let nowISO = isoString()
            let newRec = Record(deviceActivityId: deviceActivityId,
                                contentFingerprint: contentFingerprint,
                                pushed: false,
                                callingApi: true,
                                firstSeenISO: nowISO,
                                lastUpdatedISO: nowISO)
            recordsById[deviceActivityId] = newRec
            saveToDefaults()
            return true
        }
        debugPrint("WorkoutRecordStore.shouldPush: deviceActivityId=\(deviceActivityId)")
        debugPrint("  stored  → pushed=\(rec.pushed), callingApi=\(rec.callingApi), fingerprint=\(rec.contentFingerprint), firstSeen=\(rec.firstSeenISO ?? "nil"), lastUpdated=\(rec.lastUpdatedISO)")
        debugPrint("  incoming → fingerprint=\(contentFingerprint)")

        // Guard: if an API call is already in-flight for the same fingerprint, drop this duplicate.
        if !rec.pushed && rec.callingApi && rec.contentFingerprint == contentFingerprint {
            debugPrint("  result  → in-flight duplicate (callingApi=true, same fingerprint) — dropping")
            return false
        }

        if !rec.pushed {
            debugPrint("  result  → will push (previously not pushed)")
            rec.callingApi = true
            rec.lastUpdatedISO = isoString()
            recordsById[deviceActivityId] = rec
            saveToDefaults()
            return true
        }
        let changed = rec.contentFingerprint != contentFingerprint
        debugPrint("  result  → fingerprint changed=\(changed), will push=\(changed)")
        if changed {
            rec.callingApi = true
            rec.lastUpdatedISO = isoString()
            recordsById[deviceActivityId] = rec
            saveToDefaults()
        }
        return changed
    }

    /// Insert or update record with pushed=false and content fingerprint.
    public func upsertRecordPending(deviceActivityId: String, contentFingerprint: String) async {
        let nowISO = isoString()

        if var rec = recordsById[deviceActivityId] {
            rec.contentFingerprint = contentFingerprint
            rec.pushed = false
            rec.lastUpdatedISO = nowISO
            recordsById[deviceActivityId] = rec
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             contentFingerprint: contentFingerprint,
                             pushed: false,
                             firstSeenISO: nowISO,
                             lastUpdatedISO: nowISO)
            recordsById[deviceActivityId] = rec
        }
        saveToDefaults()
    }

    /// Mark a record as pushed = true and reset callingApi (creates the record if absent).
    public func markPushed(deviceActivityId: String) async {
        let nowISO = isoString()
        if var rec = recordsById[deviceActivityId] {
            rec.pushed = true
            rec.callingApi = false
            rec.lastUpdatedISO = nowISO
            recordsById[deviceActivityId] = rec
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             contentFingerprint: "",
                             pushed: true,
                             callingApi: false,
                             firstSeenISO: nowISO,
                             lastUpdatedISO: nowISO)
            recordsById[deviceActivityId] = rec
        }
        saveToDefaults()
    }

    /// Reset callingApi flag without changing pushed state.
    /// Called when an upload fails (HTTP error or network error) so the
    /// workout can be retried on the next sync cycle.
    public func resetCallingApi(deviceActivityId: String) async {
        guard var rec = recordsById[deviceActivityId] else { return }
        rec.callingApi = false
        rec.lastUpdatedISO = isoString()
        recordsById[deviceActivityId] = rec
        saveToDefaults()
        debugPrint("WorkoutRecordStore.resetCallingApi: reset for deviceActivityId=\(deviceActivityId)")
    }

    /// IDs of workouts already uploaded (pushed == true).
    public func pushedDeviceActivityIds() async -> [String] {
        return recordsById.values.filter { $0.pushed }.map { $0.deviceActivityId }
    }

    /// Return true if a record exists locally
    public func hasRecord(deviceActivityId: String) async -> Bool {
        return recordsById[deviceActivityId] != nil
    }

    /// Record the firstSeen time (idempotent)
    public func recordFirstSeen(deviceActivityId: String, date: Date = Date()) async {
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
                             contentFingerprint: "",
                             pushed: false,
                             firstSeenISO: iso,
                             lastUpdatedISO: iso)
            recordsById[deviceActivityId] = rec
            saveToDefaults()
        }
    }

    /// Update lastSeen timestamp (touch).
    public func updateLastSeen(deviceActivityId: String, date: Date = Date()) async {
        let iso = isoString(date)
        if var rec = recordsById[deviceActivityId] {
            rec.lastUpdatedISO = iso
            recordsById[deviceActivityId] = rec
        } else {
            let rec = Record(deviceActivityId: deviceActivityId,
                             contentFingerprint: "",
                             pushed: false,
                             firstSeenISO: iso,
                             lastUpdatedISO: iso)
            recordsById[deviceActivityId] = rec
        }
        saveToDefaults()
    }

    /// Remove records older than `days` (default 15)
    public func cleanupOlderThan(days: Int = 15) async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let cutoffISO = isoString(cutoff)
        recordsById = recordsById.filter { $0.value.lastUpdatedISO >= cutoffISO }
        saveToDefaults()
    }

    /// For debug: return all records as dictionaries.
    public func fetchAllRecords() async -> [[String: Any]] {
        return recordsById.values.map { rec in
            return [
                "deviceActivityId": rec.deviceActivityId,
                "contentFingerprint": rec.contentFingerprint,
                "pushed": rec.pushed,
                "callingApi": rec.callingApi,
                "firstSeenISO": rec.firstSeenISO as Any,
                "lastUpdatedISO": rec.lastUpdatedISO
            ]
        }
    }

    /// Optional: remove a specific record
    public func removeRecord(deviceActivityId: String) async {
        recordsById.removeValue(forKey: deviceActivityId)
        saveToDefaults()
    }

    /// Optional: clear all records
    public func clearAll() async {
        recordsById.removeAll()
        saveToDefaults()
    }
}
