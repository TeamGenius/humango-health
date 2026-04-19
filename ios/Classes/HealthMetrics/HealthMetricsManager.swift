//
//  HealthMetricsManager.swift
//  humango_health
//
//  On-demand HKQuantityType reader and per-metric monitor registry.
//
//  Flutter channel (com.humango.health/metrics) handles:
//    "fetchHealthMetric"        — on-demand range query (startDate, endDate)
//    "startMetricMonitoring"    — start HealthMetricMonitor for one type
//    "stopMetricMonitoring"     — stop HealthMetricMonitor for one type
//    "stopAllMetricMonitoring"  — stop all active monitors
//
//  Native iOS callers use the public fetchMetric / startMonitoring / stopMonitoring API
//  directly, or the per-type convenience wrappers on HumangoHealthPlugin.shared.
//
//  All numeric values are raw Double — no rounding applied anywhere.
//  All dates are ISO 8601 with fractional seconds.
//

import Flutter
import HealthKit
import Foundation

// MARK: - HealthMetricsManager

@available(iOS 17.0, *)
public class HealthMetricsManager: NSObject {
    public static let shared = HealthMetricsManager()

    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Monitor registry

    /// Active HealthMetricMonitor instances keyed by HealthMetricType.key.
    private var monitors: [String: HealthMetricMonitor] = [:]
    /// Barrier queue guards all reads/writes to `monitors`.
    private let monitorQueue = DispatchQueue(
        label: "com.humango.HealthMetricsManager.monitors",
        attributes: .concurrent
    )

    // MARK: - Flutter Method Channel Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "fetchHealthMetric":
            handleFetchHealthMetric(call, result: result)
        case "fetchLatestHealthMetric":
            handleFetchLatestHealthMetric(call, result: result)
        case "startMetricMonitoring":
            handleStartMonitoring(call, result: result)
        case "stopMetricMonitoring":
            handleStopMonitoring(call, result: result)
        case "stopAllMetricMonitoring":
            handleStopAllMonitoring(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Public Native iOS Fetch API

    /// On-demand query for a single metric type within a date range.
    /// All values are raw Double — no rounding.
    public func fetchMetric(
        _ metricType: HealthMetricType,
        startDate: Date,
        endDate: Date
    ) async throws -> [String: Any] {
        return try await fetchMetricSamples(
            metricType: metricType,
            startDate: startDate,
            endDate: endDate,
            limit: HKObjectQueryNoLimit,
            ascending: true
        )
    }

    /// On-demand query for the most recent sample of a single metric type.
    public func fetchLatestMetric(_ metricType: HealthMetricType) async throws -> [String: Any] {
        return try await fetchMetricSamples(
            metricType: metricType,
            startDate: Date.distantPast,
            endDate: Date(),
            limit: 1,
            ascending: false
        )
    }

    /// On-demand query for all supported metric types within a date range.
    /// Errors per type are collected in the "errors" key rather than thrown.
    public func fetchAllMetrics(startDate: Date, endDate: Date) async -> [String: Any] {

        var allMetrics: [String: Any] = [:]
        var errors: [String: String] = [:]

        for type in HealthMetricType.allCases {
            do {
                allMetrics[type.key] = try await fetchMetricSamples(
                    metricType: type,
                    startDate: startDate,
                    endDate: endDate,
                    limit: HKObjectQueryNoLimit,
                    ascending: true
                )
            } catch {
                errors[type.key] = error.localizedDescription
                debugPrint("[Humango] HealthMetricsManager: fetchAllMetrics — error for \(type.key): \(error)")
            }
        }

        return [
            "metrics": allMetrics,
            "errors": errors,
            "fetchedFrom": isoFormatter.string(from: startDate),
            "fetchedTo": isoFormatter.string(from: endDate),
        ]
    }

    // MARK: - Public Native iOS Monitor Control

    /// Start monitoring a single metric type. Idempotent — calling with an already-monitored
    /// type is a no-op (the existing monitor continues running).
    public func startMonitoring(_ metricType: HealthMetricType) {
        monitorQueue.sync {
            if monitors[metricType.key] != nil {
                debugPrint("[Humango] HealthMetricsManager: startMonitoring(\(metricType.key)) — already monitoring; skipped")
                return
            }
        }
        let monitor = HealthMetricMonitor(metricType: metricType)
        monitorQueue.async(flags: .barrier) {
            self.monitors[metricType.key] = monitor
        }
        monitor.start()
        debugPrint("[Humango] HealthMetricsManager: startMonitoring(\(metricType.key)) — monitor started")
    }

    /// Stop and remove the monitor for a single metric type.
    public func stopMonitoring(_ metricType: HealthMetricType) {
        monitorQueue.async(flags: .barrier) {
            self.monitors[metricType.key]?.invalidate()
            self.monitors.removeValue(forKey: metricType.key)
        }
        debugPrint("[Humango] HealthMetricsManager: stopMonitoring(\(metricType.key)) — monitor stopped")
    }

    /// Stop and remove all active monitors.
    public func stopAllMonitoring() {
        monitorQueue.async(flags: .barrier) {
            let keys = Array(self.monitors.keys)
            debugPrint("[Humango] HealthMetricsManager: stopAllMonitoring — stopping \(keys.count) monitor(s): \(keys)")
            for monitor in self.monitors.values { monitor.invalidate() }
            self.monitors.removeAll()
        }
    }

    // MARK: - Core HealthKit Fetch (private)

    /// Query a single metric by its **string key** (e.g. `"heartRateVariabilitySDNN"`) within a
    /// date range. Bridging convenience for callers that hold the key as a `String` rather than
    /// a `HealthMetricType` value.
    ///
    /// ```swift
    /// HealthMetricsManager.shared.fetchMetric(
    ///     key: "restingHeartRate",
    ///     startDate: start,
    ///     endDate: end
    /// ) { result in
    ///     switch result {
    ///     case .success(let payload): // use payload["samples"], payload["statistics"], …
    ///     case .failure(let error):   // handle error
    ///     }
    /// }
    /// ```
    public func fetchMetric(
        key: String,
        startDate: Date,
        endDate: Date,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let metricType = HealthMetricType(key: key) else {
            let supported = HealthMetricType.allCases.map { $0.key }.joined(separator: ", ")
            completion(.failure(NSError(
                domain: "HealthMetrics",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unknown metric type: '\(key)'. Supported: \(supported)"]
            )))
            return
        }
        fetchMetric(metricType, startDate: startDate, endDate: endDate, completion: completion)
    }

    /// Query a single metric by `HealthMetricType` within a date range, delivering the result on
    /// the main queue via a completion handler. Suitable for call sites not running inside a Swift
    /// `async` context.
    ///
    /// ```swift
    /// HealthMetricsManager.shared.fetchMetric(
    ///     .heartRateVariabilitySDNN,
    ///     startDate: Calendar.current.date(byAdding: .day, value: -30, to: Date())!,
    ///     endDate: Date()
    /// ) { result in
    ///     switch result {
    ///     case .success(let payload):
    ///         let samples = payload["samples"]        // [[String: Any]] of raw samples
    ///         let stats   = payload["statistics"]     // ["average", "min", "max", "sum"]
    ///         let count   = payload["sampleCount"]    // Int
    ///     case .failure(let error):
    ///         print("Fetch failed: \(error)")
    ///     }
    /// }
    /// ```
    public func fetchMetric(
        _ metricType: HealthMetricType,
        startDate: Date,
        endDate: Date,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        Task {
            do {
                let payload = try await fetchMetric(metricType, startDate: startDate, endDate: endDate)
                DispatchQueue.main.async { completion(.success(payload)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Query the most recent sample for a single metric type, delivering the result on the main
    /// queue via a completion handler.
    public func fetchLatestMetric(
        _ metricType: HealthMetricType,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        Task {
            do {
                let payload = try await fetchLatestMetric(metricType)
                DispatchQueue.main.async { completion(.success(payload)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Query **all** supported metric types within a date range, delivering the combined result on
    /// the main queue via a completion handler. Errors per type are collected under the `"errors"`
    /// key rather than failing the whole call.
    ///
    /// ```swift
    /// HealthMetricsManager.shared.fetchAllMetrics(
    ///     startDate: weekAgo,
    ///     endDate: now
    /// ) { payload in
    ///     let metrics = payload["metrics"] as? [String: Any]
    ///     let errors  = payload["errors"]  as? [String: String]
    /// }
    /// ```
    public func fetchAllMetrics(
        startDate: Date,
        endDate: Date,
        completion: @escaping ([String: Any]) -> Void
    ) {
        Task {
            let payload = await fetchAllMetrics(startDate: startDate, endDate: endDate)
            DispatchQueue.main.async { completion(payload) }
        }
    }

    // MARK: - Flutter Method Handlers (private)

    private func handleFetchHealthMetric(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let metricKey = args["metricType"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "metricType is required", details: nil))
            return
        }
        guard let metricType = HealthMetricType(key: metricKey) else {
            let supported = HealthMetricType.allCases.map { $0.key }.joined(separator: ", ")
            result(FlutterError(
                code: "UNKNOWN_METRIC",
                message: "Unknown metric type: \(metricKey). Supported: \(supported)",
                details: nil
            ))
            return
        }

        let startDate = parseDate(args["startDate"] as? String)
            ?? Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let endDate   = parseDate(args["endDate"]   as? String) ?? Date()

        Task {
            do {
                let response = try await fetchMetricSamples(
                    metricType: metricType,
                    startDate: startDate,
                    endDate: endDate,
                    limit: HKObjectQueryNoLimit,
                    ascending: true
                )
                DispatchQueue.main.async { result(response) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FETCH_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func handleFetchLatestHealthMetric(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let metricKey = args["metricType"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "metricType is required", details: nil))
            return
        }
        guard let metricType = HealthMetricType(key: metricKey) else {
            let supported = HealthMetricType.allCases.map { $0.key }.joined(separator: ", ")
            result(FlutterError(
                code: "UNKNOWN_METRIC",
                message: "Unknown metric type: \(metricKey). Supported: \(supported)",
                details: nil
            ))
            return
        }
        Task {
            do {
                let response = try await fetchLatestMetric(metricType)
                DispatchQueue.main.async { result(response) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FETCH_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func handleStartMonitoring(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let metricKey = args["metricType"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "metricType is required", details: nil))
            return
        }
        guard let metricType = HealthMetricType(key: metricKey) else {
            let supported = HealthMetricType.allCases.map { $0.key }.joined(separator: ", ")
            result(FlutterError(
                code: "UNKNOWN_METRIC",
                message: "Unknown metric type: \(metricKey). Supported: \(supported)",
                details: nil
            ))
            return
        }
        startMonitoring(metricType)
        result(nil)
    }

    private func handleStopMonitoring(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let metricKey = args["metricType"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "metricType is required", details: nil))
            return
        }
        guard let metricType = HealthMetricType(key: metricKey) else {
            result(FlutterError(code: "UNKNOWN_METRIC", message: "Unknown metric type: \(metricKey)", details: nil))
            return
        }
        stopMonitoring(metricType)
        result(nil)
    }

    private func handleStopAllMonitoring(result: @escaping FlutterResult) {
        stopAllMonitoring()
        result(nil)
    }

    // MARK: - Core HealthKit Fetch (private)

    /// Fetch quantity samples via HKSampleQuery.
    /// All values are raw Double — no rounding applied.
    private func fetchMetricSamples(
        metricType: HealthMetricType,
        startDate: Date,
        endDate: Date,
        limit: Int,
        ascending: Bool
    ) async throws -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthMetrics", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HealthKit is not available on this device",
            ])
        }
        guard let quantityType = metricType.quantityType else {
            throw NSError(domain: "HealthMetrics", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Quantity type not available: \(metricType.identifier.rawValue)",
            ])
        }

        let unit      = metricType.unit
        let unitLabel = metricType.unitLabel

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: ascending
        )

        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: results as? [HKQuantitySample] ?? [])
            }
            healthStore.execute(query)
        }

        var sampleDicts: [[String: Any]] = []
        var sum: Double = 0
        var minVal: Double = Double.greatestFiniteMagnitude
        var maxVal: Double = -Double.greatestFiniteMagnitude

        for sample in samples {
            // Raw doubleValue — no rounding
            let value = sample.quantity.doubleValue(for: unit)
            sampleDicts.append(convertQuantitySampleToDict(sample, value: value, unitLabel: unitLabel))
            sum += value
            if value < minVal { minVal = value }
            if value > maxVal { maxVal = value }
        }

        let count = samples.count
        let average: Double = count > 0 ? sum / Double(count) : 0
        if count == 0 { minVal = 0; maxVal = 0 }

        let latestSample: [String: Any]? = ascending ? sampleDicts.last : sampleDicts.first

        debugPrint("[Humango] HealthMetricsManager: fetchMetricSamples — \(count) \(metricType.key) sample(s) [\(isoFormatter.string(from: startDate)) → \(isoFormatter.string(from: endDate))]")

        return [
            "metricType": metricType.key,
            "unit": unitLabel,
            "samples": sampleDicts,
            "sampleCount": count,
            "latestSample": latestSample as Any,
            "statistics": [
                "average": average,
                "min": minVal,
                "max": maxVal,
                "sum": sum,
            ] as [String: Double],
            "fetchedFrom": isoFormatter.string(from: startDate),
            "fetchedTo": isoFormatter.string(from: endDate),
        ]
    }

    // MARK: - Convert Sample to Dictionary

    private func convertQuantitySampleToDict(
        _ sample: HKQuantitySample,
        value: Double,
        unitLabel: String
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "uuid": sample.uuid.uuidString,
            "value": value,
            "unit": unitLabel,
            "startDate": isoFormatter.string(from: sample.startDate),
            "endDate": isoFormatter.string(from: sample.endDate),
            "sourceName": sample.sourceRevision.source.name,
            "sourceBundle": sample.sourceRevision.source.bundleIdentifier,
        ]

        if let device = sample.device {
            var deviceDict: [String: Any] = [:]
            if let name = device.name { deviceDict["name"] = name }
            if let model = device.model { deviceDict["model"] = model }
            if let manufacturer = device.manufacturer { deviceDict["manufacturer"] = manufacturer }
            if let hardwareVersion = device.hardwareVersion { deviceDict["hardwareVersion"] = hardwareVersion }
            if let softwareVersion = device.softwareVersion { deviceDict["softwareVersion"] = softwareVersion }
            if let localIdentifier = device.localIdentifier { deviceDict["localIdentifier"] = localIdentifier }
            dict["device"] = deviceDict
        }

        if let metadata = sample.metadata, !metadata.isEmpty {
            var metadataDict: [String: Any] = [:]
            for (key, metaValue) in metadata {
                if let stringValue = metaValue as? String {
                    metadataDict[key] = stringValue
                } else if let numberValue = metaValue as? NSNumber {
                    metadataDict[key] = numberValue
                } else if let dateValue = metaValue as? Date {
                    metadataDict[key] = isoFormatter.string(from: dateValue)
                } else {
                    metadataDict[key] = String(describing: metaValue)
                }
            }
            dict["metadata"] = metadataDict
        }
        
        return dict
    }
    
    // MARK: - Helpers
    
    private func parseDate(_ dateString: String?) -> Date? {
        guard let str = dateString else { return nil }
        return ISO8601DateFormatter().date(from: str) ?? isoFormatter.date(from: str)
    }
}
