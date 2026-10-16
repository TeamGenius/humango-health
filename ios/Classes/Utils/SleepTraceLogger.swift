//
//  SleepTraceLogger.swift
//  humango_health
//
//  TEMPORARY trace logger for the sleep pipeline. Posts raw data only (no analysis)
//  as JSON to `endpoint`. Every entry carries:
//    runId      — one id per pipeline run (one background fire, or one foreground day window)
//    seq        — 1-based step number within that run
//    globalSeq  — process-wide counter across all runs
//
//  Set `SleepTraceLogger.isEnabled = false` before release.
//

import Foundation
import HealthKit
import UIKit

public final class SleepTraceLogger {

    public static let shared = SleepTraceLogger()

    public static var isEnabled = true

    public static var endpoint = URL(string: "https://sample-logger-1065871031102.asia-southeast1.run.app/samples")!

    /// Host-app context merged into every entry (e.g. athleteId). Evaluated per entry.
    public static var contextProvider: (() -> [String: Any])?

    /// Run id propagated through `async` calls via `SleepTraceLogger.$currentRunId.withValue`.
    @TaskLocal public static var currentRunId: String?

    private let lock = NSLock()
    private var seqByRun: [String: Int] = [:]
    private var globalSeq = 0
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

    private init() {}

    /// Unique, readable run id, e.g. `BG-20261014T075312-3F2A9C`.
    public static func makeRunId(prefix: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = .current
        return "\(prefix)-\(f.string(from: Date()))-\(UUID().uuidString.prefix(6))"
    }

    /// Posts one entry. Uses `runId`, else the task-local `currentRunId`, else `"ADHOC"`.
    public func log(_ step: String, runId: String? = nil, data: [String: Any] = [:]) {
        guard Self.isEnabled else { return }
        let resolvedRunId = runId ?? Self.currentRunId ?? "ADHOC"

        lock.lock()
        let seq = (seqByRun[resolvedRunId] ?? 0) + 1
        seqByRun[resolvedRunId] = seq
        globalSeq += 1
        let gSeq = globalSeq
        lock.unlock()

        let now = Date()
        let info = Bundle.main.infoDictionary
        var entry: [String: Any] = [
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
            "data": data,
        ]
        if let ctx = Self.contextProvider?() { entry["context"] = ctx }
        send(entry)
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

    private func send(_ entry: [String: Any]) {
        let safe = Self.jsonSafe(entry)
        guard JSONSerialization.isValidJSONObject(safe),
              let body = try? JSONSerialization.data(withJSONObject: safe, options: []) else { return }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let id = UUID()
        let task = Task { [weak self] in
            _ = try? await URLSession.shared.data(for: request)
            self?.removePending(id)
        }
        lock.lock()
        pending[id] = task
        lock.unlock()
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

    /// Raw HealthKit fields of one sample, as returned by the query.
    public static func raw(_ s: HKCategorySample, index: Int) -> [String: Any] {
        let rev = s.sourceRevision
        let os = rev.operatingSystemVersion
        return [
            "index": index,
            "uuid": s.uuid.uuidString,
            "value": s.value,
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

    /// Posts every sample, chunked so each request stays small.
    public func logSamples(_ step: String, samples: [HKCategorySample], extra: [String: Any] = [:], chunkSize: Int = 40) {
        guard Self.isEnabled else { return }
        let rows = samples.enumerated().map { Self.raw($0.element, index: $0.offset) }
        let chunkCount = max(1, Int(ceil(Double(rows.count) / Double(chunkSize))))
        for c in 0..<chunkCount {
            let lo = c * chunkSize
            let hi = min(lo + chunkSize, rows.count)
            var data = extra
            data["totalSampleCount"] = samples.count
            data["chunkIndex"] = c + 1
            data["chunkCount"] = chunkCount
            data["samples"] = lo < hi ? Array(rows[lo..<hi]) : []
            log(step, data: data)
        }
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
