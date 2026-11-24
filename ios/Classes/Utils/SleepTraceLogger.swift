//
//  SleepTraceLogger.swift
//  humango_health
//
//  TEMPORARY trace logger for the sleep pipeline (HB-14864). Posts raw data only (no analysis
//  decisions are changed) as JSON to `endpoint` — the sleep-trace-logger service, which stores
//  each entry in Supabase as one row: date-time + the full JSON string.
//
//  Every entry carries:
//    entryId    — unique per entry; the server ignores a retried entry it already stored
//    runId      — one id per pipeline run (one background fire, one foreground call, one live batch)
//    seq        — 1-based step number within that run
//    globalSeq  — process-wide counter across all runs
//    droppedEntriesSoFar — entries this process gave up on after retries (so loss is visible)
//
//  Size: an entry whose JSON exceeds `maxEntryBytes` is split into parts (partIndex/partCount)
//  by slicing its largest top-level array; anything that still cannot fit is replaced by a
//  marker with its original size, never silently dropped.
//
//  Set `SleepTraceLogger.isEnabled = false` before release.
//

import Foundation
import HealthKit
import UIKit

public final class SleepTraceLogger {

    public static let shared = SleepTraceLogger()

    public static var isEnabled = true

    /// sleep-trace-logger service. Override from the host app for local testing.
    public static var endpoint = URL(string: "https://sample-logger-1065871031102.asia-southeast1.run.app/samples")!

    /// Optional shared token, sent as `x-trace-token` when the service has TRACE_TOKEN set.
    public static var authToken: String?

    /// Largest JSON body sent in one request; bigger entries are split into parts.
    /// The service accepts 50 MB; a night of samples is normally well under 1 MB.
    public static var maxEntryBytes = 20_000_000

    /// Attempts per entry (1 = no retry).
    public static var maxAttempts = 3

    /// Host-app context merged into every entry (e.g. athleteId). Evaluated per entry.
    public static var contextProvider: (() -> [String: Any])?

    /// Run id propagated through `async` calls via `SleepTraceLogger.$currentRunId.withValue`.
    @TaskLocal public static var currentRunId: String?

    private let lock = NSLock()
    private var seqByRun: [String: Int] = [:]
    private var globalSeq = 0
    private var droppedEntries = 0
    private var pending: [UUID: Task<Void, Never>] = [:]

    private static let utcFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
        f.timeZone = .current
        return f
    }()

    private static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buf in
            String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    private init() {}

    /// Unique, readable run id, e.g. `BG-20261014T075312-3F2A9C`.
    public static func makeRunId(prefix: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = .current
        return "\(prefix)-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6))"
    }

    /// Runs `body` under the current run id, or under a new one with `prefix` when none is set.
    public static func withRun<T>(prefix: String, _ body: () async throws -> T) async rethrows -> T {
        if currentRunId != nil { return try await body() }
        return try await $currentRunId.withValue(makeRunId(prefix: prefix)) { try await body() }
    }

    // MARK: - Logging

    /// Posts one entry. Uses `runId`, else the task-local `currentRunId`, else `"ADHOC"`.
    /// `keepAlive: true` asks iOS for background time until the post finishes, for events logged
    /// while the app is going to (or waking in) the background, where it could otherwise be
    /// suspended before the request completes.
    public func log(_ step: String, runId: String? = nil, data: [String: Any] = [:], keepAlive: Bool = false) {
        guard Self.isEnabled else { return }
        let resolvedRunId = runId ?? Self.currentRunId ?? "ADHOC"

        lock.lock()
        let seq = (seqByRun[resolvedRunId] ?? 0) + 1
        seqByRun[resolvedRunId] = seq
        globalSeq += 1
        let gSeq = globalSeq
        let dropped = droppedEntries
        lock.unlock()

        let now = Date()
        let info = Bundle.main.infoDictionary
        var entry: [String: Any] = [
            "entryId": UUID().uuidString.lowercased(),
            "logType": "sleep_trace",
            "runId": resolvedRunId,
            "seq": seq,
            "globalSeq": gSeq,
            "step": step,
            "loggedAtUtc": Self.utcFormatter.string(from: now),
            "loggedAtLocal": Self.localFormatter.string(from: now),
            "timezone": TimeZone.current.identifier,
            "timezoneOffsetSeconds": TimeZone.current.secondsFromGMT(for: now),
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
            "appBuild": info?["CFBundleVersion"] as? String ?? "",
            "osVersion": UIDevice.current.systemVersion,
            "deviceModel": Self.deviceModel,
            "droppedEntriesSoFar": dropped,
            "data": data,
        ]
        if let ctx = Self.contextProvider?() { entry["context"] = ctx }
        for part in Self.fitToSize(Self.jsonSafe(entry) as? [String: Any] ?? [:]) {
            send(part, keepAlive: keepAlive)
        }
    }

    /// Posts every sample with full raw fields in ONE entry (one row / one JSON string on the server).
    /// Only an entry over `maxEntryBytes` is split, by `fitToSize`.
    public func logSamples(_ step: String, samples: [HKCategorySample], extra: [String: Any] = [:]) {
        guard Self.isEnabled else { return }
        var data = extra
        data["totalSampleCount"] = samples.count
        data["samples"] = samples.enumerated().map { Self.raw($0.element, index: $0.offset) }
        log(step, data: data)
    }

    /// Waits for all in-flight posts (call before HealthKit `completion()`).
    public func flush() async {
        for t in pendingTasks() { _ = await t.result }
    }

    private func pendingTasks() -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return Array(pending.values)
    }

    // MARK: - Size handling

    private static func encodedSize(_ obj: Any) -> Int {
        (try? JSONSerialization.data(withJSONObject: obj, options: []))?.count ?? Int.max
    }

    /// Returns the entry as-is when it fits, otherwise parts that each fit `maxEntryBytes`.
    /// Splits the largest top-level array in `data`; other `data` keys go only in part 1.
    static func fitToSize(_ entry: [String: Any]) -> [[String: Any]] {
        let size = encodedSize(entry)
        if size <= maxEntryBytes { return [entry] }

        let data = entry["data"] as? [String: Any] ?? [:]
        let arrayKeys = data.compactMap { key, value -> (String, [Any], Int)? in
            guard let arr = value as? [Any], arr.count > 1 else { return nil }
            return (key, arr, encodedSize(arr))
        }
        guard let (key, array, arrayBytes) = arrayKeys.max(by: { $0.2 < $1.2 }) else {
            return [oversizeMarker(entry, originalBytes: size)]
        }

        // Part 1: everything except the array; then the array in slices sized to fit.
        var head = data
        head[key] = []
        head["splitArrayKey"] = key
        head["splitArrayCount"] = array.count
        let headBytes = encodedSize(head)
        let perItem = max(1, arrayBytes / max(1, array.count))
        let budget = max(perItem, maxEntryBytes - 4_096)
        let itemsPerPart = max(1, budget / perItem)

        var datas: [[String: Any]] = []
        if headBytes > 512 { datas.append(head) }   // only a separate part when it carries real content
        var lo = 0
        while lo < array.count {
            let hi = min(lo + itemsPerPart, array.count)
            var d: [String: Any] = ["splitArrayKey": key, "splitArrayCount": array.count, "splitArrayOffset": lo]
            d[key] = Array(array[lo..<hi])
            if datas.isEmpty { d = head.merging(d) { $1 } }
            datas.append(d)
            lo = hi
        }

        let total = datas.count
        return datas.enumerated().flatMap { idx, d -> [[String: Any]] in
            var part = entry
            part["entryId"] = UUID().uuidString.lowercased()
            part["partIndex"] = idx + 1
            part["partCount"] = total
            part["data"] = d
            // A slice can still be too big (one huge element): fall back to a marker for that part.
            return encodedSize(part) <= maxEntryBytes ? [part] : [oversizeMarker(part, originalBytes: encodedSize(part))]
        }
    }

    private static func oversizeMarker(_ entry: [String: Any], originalBytes: Int) -> [String: Any] {
        var marker = entry
        let data = entry["data"] as? [String: Any] ?? [:]
        marker["entryId"] = UUID().uuidString.lowercased()
        marker["data"] = [
            "oversize": true,
            "originalBytes": originalBytes,
            "maxEntryBytes": maxEntryBytes,
            "keys": Array(data.keys).sorted(),
            "keyBytes": data.mapValues { encodedSize([$0]) },
        ]
        return marker
    }

    // MARK: - Transport

    private func send(_ entry: [String: Any], keepAlive: Bool = false) {
        guard JSONSerialization.isValidJSONObject(entry),
              let body = try? JSONSerialization.data(withJSONObject: entry, options: []) else {
            noteDropped(reason: "not serialisable", step: entry["step"])
            return
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = Self.authToken { request.setValue(token, forHTTPHeaderField: "x-trace-token") }
        request.httpBody = body
        request.timeoutInterval = 30

        let id = UUID()
        let step = entry["step"]
        let stepName = "\(step ?? "")"
        let task = Task { [weak self] in
            // Background time so iOS doesn't suspend the app mid-request.
            let bgTime = keepAlive ? await Self.beginBackgroundTime("SleepTraceLogger.\(stepName)") : nil
            var lastProblem = "unknown"
            for attempt in 1...max(1, Self.maxAttempts) {
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(status) { lastProblem = ""; break }
                    lastProblem = "HTTP \(status)"
                    if (400..<500).contains(status) && status != 408 && status != 429 { break } // not retryable
                } catch {
                    lastProblem = "\(error.localizedDescription)"
                }
                if attempt < Self.maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
            }
            if !lastProblem.isEmpty { self?.noteDropped(reason: lastProblem, step: step) }
            if let bgTime { await Self.endBackgroundTime(bgTime) }
            self?.removePending(id)
        }
        lock.lock()
        pending[id] = task
        lock.unlock()
    }

    /// Holds a UIKit background-task id so the expiration handler can end it.
    private final class BackgroundTime {
        var id: UIBackgroundTaskIdentifier = .invalid
    }

    @MainActor
    private static func beginBackgroundTime(_ name: String) -> BackgroundTime {
        let box = BackgroundTime()
        box.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // iOS is about to suspend us: end the task so the app isn't killed.
            if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id) }
            box.id = .invalid
        }
        return box
    }

    @MainActor
    private static func endBackgroundTime(_ box: BackgroundTime) {
        if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id) }
        box.id = .invalid
    }

    private func noteDropped(reason: String, step: Any?) {
        lock.lock()
        droppedEntries += 1
        lock.unlock()
        debugPrint("[SleepTraceLogger] dropped entry step=\(step ?? "?"): \(reason)")
    }

    private func removePending(_ id: UUID) {
        lock.lock()
        pending[id] = nil
        lock.unlock()
    }

    // MARK: - Raw data helpers

    public static func utc(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return utcFormatter.string(from: date)
    }

    public static func local(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return localFormatter.string(from: date)
    }

    /// Readable name for an `HKCategoryValueSleepAnalysis` raw value.
    public static func stageName(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed:             return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake:             return "awake"
        case .asleepCore:        return "asleepCore"
        case .asleepDeep:        return "asleepDeep"
        case .asleepREM:         return "asleepREM"
        default:                 return "unknown(\(value))"
        }
    }

    /// Raw HealthKit fields of one sample, as returned by the query.
    public static func raw(_ s: HKCategorySample, index: Int) -> [String: Any] {
        let rev = s.sourceRevision
        let os = rev.operatingSystemVersion
        return [
            "index": index,
            "uuid": s.uuid.uuidString,
            "value": s.value,
            "stage": stageName(s.value),
            "durationSeconds": s.endDate.timeIntervalSince(s.startDate),
            "syncIdentifier": s.metadata?[HKMetadataKeySyncIdentifier] ?? NSNull(),
            "syncVersion": s.metadata?[HKMetadataKeySyncVersion] ?? NSNull(),
            "externalUUID": s.metadata?[HKMetadataKeyExternalUUID] ?? NSNull(),
            "wasUserEntered": s.metadata?[HKMetadataKeyWasUserEntered] ?? NSNull(),
            "startUtc": utc(s.startDate),
            "endUtc": utc(s.endDate),
            "startLocal": local(s.startDate),
            "endLocal": local(s.endDate),
            "sourceName": rev.source.name,
            "sourceBundle": rev.source.bundleIdentifier,
            "sourceRevisionVersion": rev.version ?? NSNull(),
            "sourceRevisionProductType": rev.productType ?? NSNull(),
            "sourceRevisionOS": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "device": s.device.map { dev -> [String: Any] in
                [
                    "name": dev.name ?? NSNull(),
                    "model": dev.model ?? NSNull(),
                    "manufacturer": dev.manufacturer ?? NSNull(),
                    "hardwareVersion": dev.hardwareVersion ?? NSNull(),
                    "firmwareVersion": dev.firmwareVersion ?? NSNull(),
                    "softwareVersion": dev.softwareVersion ?? NSNull(),
                    "localIdentifier": dev.localIdentifier ?? NSNull(),
                    "udiDeviceIdentifier": dev.udiDeviceIdentifier ?? NSNull(),
                ]
            } ?? NSNull(),
            "metadata": s.metadata ?? [:],
        ]
    }

    // MARK: - Interval helpers (facts only; never used by the calculation itself)

    /// Merges intervals into a sorted, non-overlapping list.
    static func mergeIntervals(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var out: [(Date, Date)] = []
        for iv in sorted {
            if let last = out.last, iv.0 <= last.1 {
                out[out.count - 1] = (last.0, max(last.1, iv.1))
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// Seconds covered by the union of the given intervals (overlaps counted once).
    static func unionSeconds(_ intervals: [(Date, Date)]) -> Double {
        mergeIntervals(intervals).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }

    /// Seconds of `interval` that fall inside the union of `others`.
    static func intersectionSeconds(_ interval: (Date, Date), with others: [(Date, Date)]) -> Double {
        mergeIntervals(others).reduce(0) { acc, o in
            let lo = max(interval.0, o.0), hi = min(interval.1, o.1)
            return hi > lo ? acc + hi.timeIntervalSince(lo) : acc
        }
    }

    private static let asleepValues: Set<Int> = [
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
    ]

    /// Per-sample trace of the aggregation loop, in the exact order the loop adds samples.
    /// Each row is the full raw sample plus: how many of its seconds were already counted by
    /// earlier samples (any stage / same stage), and the running per-stage totals after it.
    public static func aggregationSteps(_ samplesInLoopOrder: [HKCategorySample]) -> [[String: Any]] {
        var running: [String: Double] = ["inBed": 0, "unspecified": 0, "awake": 0, "core": 0, "deep": 0, "rem": 0]
        var priorAll: [(Date, Date)] = []
        var priorByStage: [Int: [(Date, Date)]] = [:]
        var priorAsleep: [(Date, Date)] = []
        var rows: [[String: Any]] = []

        for (i, s) in samplesInLoopOrder.enumerated() {
            let iv = (s.startDate, s.endDate)
            let dur = s.endDate.timeIntervalSince(s.startDate)
            let key: String?
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .inBed:             key = "inBed"
            case .asleepUnspecified: key = "unspecified"
            case .awake:             key = "awake"
            case .asleepCore:        key = "core"
            case .asleepDeep:        key = "deep"
            case .asleepREM:         key = "rem"
            default:                 key = nil
            }
            let overlapAll = intersectionSeconds(iv, with: priorAll)
            let overlapSame = intersectionSeconds(iv, with: priorByStage[s.value] ?? [])
            let overlapAsleep = asleepValues.contains(s.value) ? intersectionSeconds(iv, with: priorAsleep) : 0
            if let key { running[key, default: 0] += dur }

            var row = raw(s, index: i)
            row["sampleIndex"] = i
            row["countedAs"] = key ?? "ignored"
            row["addedSeconds"] = key == nil ? 0 : dur
            row["overlapWithPriorSeconds"] = overlapAll
            row["overlapWithPriorSameStageSeconds"] = overlapSame
            row["overlapWithPriorAsleepSeconds"] = overlapAsleep
            row["doubleCountedSeconds"] = (key != nil && asleepValues.contains(s.value)) ? overlapAsleep : 0
            row["cumulative"] = running.merging(["totalSleep": running["core"]! + running["deep"]! + running["rem"]!]) { $1 }
            rows.append(row)

            priorAll.append(iv)
            priorByStage[s.value, default: []].append(iv)
            if asleepValues.contains(s.value) { priorAsleep.append(iv) }
        }
        return rows
    }

    /// Raw overlap facts for one set of samples (normally one source's samples for one night):
    /// summed vs. covered seconds per stage, every overlapping pair, and how the samples split
    /// by source app version and HealthKit sync identifier. Facts only; no samples are dropped.
    public static func overlapReport(_ samples: [HKCategorySample], maxPairs: Int = 500) -> [String: Any] {
        let sorted = samples.sorted { $0.startDate < $1.startDate }

        var summedByStage: [String: Double] = [:]
        var intervalsByStage: [String: [(Date, Date)]] = [:]
        var asleepIntervals: [(Date, Date)] = []
        for s in sorted {
            let stage = stageName(s.value)
            summedByStage[stage, default: 0] += s.endDate.timeIntervalSince(s.startDate)
            intervalsByStage[stage, default: []].append((s.startDate, s.endDate))
            if asleepValues.contains(s.value) { asleepIntervals.append((s.startDate, s.endDate)) }
        }
        let coveredByStage = intervalsByStage.mapValues { unionSeconds($0) }
        let summedAsleep = ["asleepCore", "asleepDeep", "asleepREM", "asleepUnspecified"]
            .reduce(0.0) { $0 + (summedByStage[$1] ?? 0) }

        var pairs: [[String: Any]] = []
        var pairCount = 0
        var overlapSecondsTotal: Double = 0
        for i in 0..<sorted.count {
            let a = sorted[i]
            var j = i + 1
            while j < sorted.count, sorted[j].startDate < a.endDate {
                let b = sorted[j]
                let overlap = min(a.endDate, b.endDate).timeIntervalSince(b.startDate)
                if overlap > 0 {
                    pairCount += 1
                    overlapSecondsTotal += overlap
                    if pairs.count < maxPairs {
                        pairs.append([
                            "aUUID": a.uuid.uuidString, "aStage": stageName(a.value),
                            "aStartLocal": local(a.startDate), "aEndLocal": local(a.endDate),
                            "aSourceVersion": a.sourceRevision.version ?? NSNull(),
                            "aSyncIdentifier": a.metadata?[HKMetadataKeySyncIdentifier] ?? NSNull(),
                            "bUUID": b.uuid.uuidString, "bStage": stageName(b.value),
                            "bStartLocal": local(b.startDate), "bEndLocal": local(b.endDate),
                            "bSourceVersion": b.sourceRevision.version ?? NSNull(),
                            "bSyncIdentifier": b.metadata?[HKMetadataKeySyncIdentifier] ?? NSNull(),
                            "overlapSeconds": overlap,
                            "sameStage": a.value == b.value,
                            "identicalInterval": a.startDate == b.startDate && a.endDate == b.endDate,
                        ])
                    }
                }
                j += 1
            }
        }

        let bySourceVersion = Dictionary(grouping: sorted) { $0.sourceRevision.version ?? "nil" }
            .mapValues { list -> [String: Any] in
                [
                    "sampleCount": list.count,
                    "firstStartLocal": local(list.map(\.startDate).min()),
                    "lastEndLocal": local(list.map(\.endDate).max()),
                ]
            }
        let bySyncIdentifier = Dictionary(grouping: sorted) {
            ($0.metadata?[HKMetadataKeySyncIdentifier] as? String) ?? "nil"
        }.mapValues { list -> [String: Any] in
            [
                "sampleCount": list.count,
                "syncVersions": Array(Set(list.map { "\($0.metadata?[HKMetadataKeySyncVersion] ?? "nil")" })).sorted(),
            ]
        }

        let minStart = sorted.map(\.startDate).min()
        let maxEnd = sorted.map(\.endDate).max()
        let windowSeconds = (minStart != nil && maxEnd != nil) ? maxEnd!.timeIntervalSince(minStart!) : 0
        return [
            "sampleCount": sorted.count,
            "distinctUUIDCount": Set(sorted.map(\.uuid)).count,
            "windowStartLocal": local(minStart),
            "windowEndLocal": local(maxEnd),
            "windowSeconds": windowSeconds,
            "summedSecondsByStage": summedByStage,
            "coveredSecondsByStage": coveredByStage,
            "summedAsleepSeconds": summedAsleep,
            "coveredAsleepSeconds": unionSeconds(asleepIntervals),
            "summedAsleepToWindowRatio": windowSeconds > 0 ? summedAsleep / windowSeconds : NSNull(),
            "overlappingPairCount": pairCount,
            "overlapSecondsTotal": overlapSecondsTotal,
            "overlappingPairs": pairs,
            "overlappingPairsTruncated": pairCount > pairs.count,
            "bySourceVersion": bySourceVersion,
            "bySyncIdentifier": bySyncIdentifier,
        ]
    }

    /// Converts any value into something `JSONSerialization` accepts.
    public static func jsonSafe(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return jsonSafe(child.value)
        }
        switch value {
        case is NSNull:              return value
        case let v as String:        return v
        case let v as Bool:          return v
        case let v as Int:           return v
        case let v as Double:        return v.isFinite ? v : String(v)
        case let v as NSNumber:      return v
        case let v as Date:          return utcFormatter.string(from: v)
        case let v as UUID:          return v.uuidString
        case let v as [String: Any]: return v.mapValues { jsonSafe($0) }
        case let v as [Any]:         return v.map { jsonSafe($0) }
        default:                     return String(describing: value)
        }
    }
}
