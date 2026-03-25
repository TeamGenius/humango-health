//
//  HRVObserverManager.swift
//  humango_health
//
//  Observes HealthKit quantity samples (HRV, heart rate, resting HR, body composition, etc.)
//  and reads new data when it is added. Works in foreground, background, and when the app is
//  suspended (iOS wakes the app briefly via enableBackgroundDelivery).
//

import Foundation
import HealthKit
import Flutter

// MARK: - UserDefaults Keys

private struct HRVObserverKeys {
    static let monitoringEnabled = "com.humango.health.hrvMonitoringEnabled"
    /// Removed — cleared on start so leftover JSON is not mistaken for live state.
    static let legacyPendingUpdates = "com.humango.health.hrvPendingUpdates"
    static let legacyLastAnchor = "com.humango.health.hrvLastAnchor"
}

// MARK: - Per-type fetch tuning

/// Keys match `HealthMetricsManager` / Dart `HealthMetricType.key`.
private struct ObservableQuantityMetric {
    let metricKey: String
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let unitLabel: String
    /// HealthKit query lookback from now.
    let lookbackDays: Int
    let sampleLimit: Int
}

/// All quantity metrics we push to the host `HumangoHealthDataDelegate` and mirror on the
/// (foreground-only) EventChannel. No UserDefaults queue — background delivery uses the delegate.
/// Heart rate is high-volume: short window + higher cap; others use a modest weekly window.
private let observedQuantityMetrics: [ObservableQuantityMetric] = [
    ObservableQuantityMetric(
        metricKey: "heartRateVariabilitySDNN",
        identifier: .heartRateVariabilitySDNN,
        unit: HKUnit.secondUnit(with: .milli),
        unitLabel: "ms",
        lookbackDays: 7,
        sampleLimit: 100
    ),
    ObservableQuantityMetric(
        metricKey: "heartRate",
        identifier: .heartRate,
        unit: HKUnit.count().unitDivided(by: .minute()),
        unitLabel: "bpm",
        lookbackDays: 1,
        sampleLimit: 500
    ),
    ObservableQuantityMetric(
        metricKey: "restingHeartRate",
        identifier: .restingHeartRate,
        unit: HKUnit.count().unitDivided(by: .minute()),
        unitLabel: "bpm",
        lookbackDays: 7,
        sampleLimit: 100
    ),
    ObservableQuantityMetric(
        metricKey: "bodyFatPercentage",
        identifier: .bodyFatPercentage,
        unit: HKUnit.percent(),
        unitLabel: "%",
        lookbackDays: 30,
        sampleLimit: 100
    ),
    ObservableQuantityMetric(
        metricKey: "bodyMass",
        identifier: .bodyMass,
        unit: HKUnit.gramUnit(with: .kilo),
        unitLabel: "kg",
        lookbackDays: 30,
        sampleLimit: 100
    ),
    ObservableQuantityMetric(
        metricKey: "height",
        identifier: .height,
        unit: HKUnit.meterUnit(with: .centi),
        unitLabel: "cm",
        lookbackDays: 365,
        sampleLimit: 50
    ),
]

// MARK: - HRVObserverManager

/// Manages HKObserverQuery + background delivery for quantity vitals and body metrics.
public class HRVObserverManager: NSObject, AppLifecycleObserver {
    static let shared = HRVObserverManager()

    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var observerQueries: [String: HKObserverQuery] = [:]
    private var isMonitoring = false
    private var eventSink: FlutterEventSink?

    private override init() {
        super.init()
        AppLifecycleManager.shared.addObserver(self)
    }

    deinit {
        AppLifecycleManager.shared.removeObserver(self)
    }

    // MARK: - Public API

    /// Whether metric observation has been started and is persisted (for auto-start on launch).
    var isMonitoringEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: HRVObserverKeys.monitoringEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: HRVObserverKeys.monitoringEnabled); UserDefaults.standard.synchronize() }
    }

    /// Attach Flutter event sink to stream metric updates when in foreground.
    func attachEventSink(_ sink: FlutterEventSink?) {
        self.eventSink = sink
    }

    /// Start observing all configured quantity types and enable background delivery for each.
    func startMonitoring() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            print("📊 [Quantity metrics observer] startMonitoring ignored — user not logged in")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            print("📊 [Quantity metrics observer] HealthKit not available")
            return
        }

        if isMonitoring {
            print("📊 [Quantity metrics observer] Already monitoring")
            return
        }

        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyPendingUpdates)
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyLastAnchor)

        isMonitoring = true
        isMonitoringEnabled = true

        Task {
            for config in observedQuantityMetrics {
                guard let qType = HKQuantityType.quantityType(forIdentifier: config.identifier) else { continue }
                do {
                    try await healthStore.enableBackgroundDelivery(for: qType, frequency: .immediate)
                    print("📊 [Quantity metrics observer] Enabled background delivery for \(config.metricKey)")
                } catch {
                    print("📊 [Quantity metrics observer] enableBackgroundDelivery failed (\(config.metricKey)): \(error)")
                }
            }
        }

        let predicate = HKQuery.predicateForSamples(withStart: nil, end: nil, options: .strictStartDate)
        for config in observedQuantityMetrics {
            guard let quantityType = HKQuantityType.quantityType(forIdentifier: config.identifier) else {
                print("📊 [Quantity metrics observer] Type unavailable: \(config.metricKey)")
                continue
            }
            let key = config.metricKey
            let query = HKObserverQuery(sampleType: quantityType, predicate: predicate) { [weak self] _, completion, error in
                guard let self = self else { completion(); return }
                defer { completion() }
                if let error = error {
                    print("📊 [Quantity metrics observer] Observer error (\(key)): \(error)")
                    return
                }
                print("📊 [Quantity metrics observer] HealthKit changed — \(key)")
                Task {
                    await self.fetchAndDeliverUpdates(metricKey: key)
                }
            }
            healthStore.execute(query)
            observerQueries[key] = query
        }

        print("📊 [Quantity metrics observer] Started \(observerQueries.count) observer(s)")
        Task {
            for config in observedQuantityMetrics {
                await fetchAndDeliverUpdates(metricKey: config.metricKey)
            }
        }
    }

    /// Stop observing and disable background delivery for all types.
    func stopMonitoring() {
        for (_, query) in observerQueries {
            healthStore.stop(query)
        }
        observerQueries.removeAll()

        for config in observedQuantityMetrics {
            guard let qType = HKQuantityType.quantityType(forIdentifier: config.identifier) else { continue }
            healthStore.disableBackgroundDelivery(for: qType) { success, error in
                if let error = error {
                    print("📊 [Quantity metrics observer] disableBackgroundDelivery error (\(config.metricKey)): \(error)")
                } else if success {
                    print("📊 [Quantity metrics observer] Disabled background delivery for \(config.metricKey)")
                }
            }
        }

        isMonitoring = false
        isMonitoringEnabled = false
        eventSink = nil
        print("📊 [Quantity metrics observer] Stopped all metric monitoring")
    }

    /// Clear all state (e.g. on logout). Stops monitoring.
    func stopAndClearAll() {
        stopMonitoring()
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyPendingUpdates)
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyLastAnchor)
        UserDefaults.standard.synchronize()
        print("📊 [Quantity metrics observer] Cleared all state")
    }

    /// Legacy API: pending batches are no longer stored. Use `HumangoHealthDataDelegate`
    /// (`onHealthMetricSamplesReady`) for background delivery; returns `[]` always.
    func retrievePendingHRVUpdates() -> [[String: Any]] {
        []
    }

    /// Auto-start on app launch when the user is logged in and monitoring was left enabled.
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            print("📊 [Quantity metrics observer] Auto-start skipped — user not logged in")
            return
        }
        guard !isMonitoring else {
            print("📊 [Quantity metrics observer] Auto-start skipped — already monitoring")
            return
        }
        guard isMonitoringEnabled else {
            print("📊 [Quantity metrics observer] Auto-start skipped — monitoring not enabled")
            return
        }
        startMonitoring()
        print("📊 [Quantity metrics observer] Auto-started from persisted preference")
    }

    // MARK: - AppLifecycleObserver

    public func appDidEnterForeground() {
        Task {
            for config in observedQuantityMetrics {
                await fetchAndDeliverUpdates(metricKey: config.metricKey)
            }
        }
    }

    public func appDidEnterBackground() {}

    // MARK: - Fetch and Deliver

    private func config(forMetricKey key: String) -> ObservableQuantityMetric? {
        observedQuantityMetrics.first { $0.metricKey == key }
    }

    private func fetchAndDeliverUpdates(metricKey: String) async {
        guard let config = config(forMetricKey: metricKey) else { return }
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: config.identifier) else { return }

        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -config.lookbackDays, to: endDate) ?? endDate
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        do {
            let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKQuantitySample], Error>) in
                let query = HKSampleQuery(
                    sampleType: quantityType,
                    predicate: predicate,
                    limit: config.sampleLimit,
                    sortDescriptors: [sortDescriptor]
                ) { _, results, error in
                    if let error = error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
                }
                healthStore.execute(query)
            }

            let sampleDicts = samples.map {
                convertToDict($0, unit: config.unit, unitLabel: config.unitLabel)
            }
            let payload: [String: Any] = [
                "metricType": config.metricKey,
                "unit": config.unitLabel,
                "samples": sampleDicts,
                "sampleCount": sampleDicts.count,
                "fetchedAt": isoFormatter.string(from: Date()),
            ]

            deliverMetricPayloadToDelegate(payload)

            if AppLifecycleManager.shared.isInForeground, let sink = eventSink {
                DispatchQueue.main.async { sink(payload) }
                print("📊 [Quantity metrics observer] Delivered \(sampleDicts.count) sample(s) to Flutter (\(metricKey))")
            } else {
                print("📊 [Quantity metrics observer] Background batch (\(metricKey)) — delegated only, count=\(sampleDicts.count)")
            }
        } catch {
            print("📊 [Quantity metrics observer] Fetch error (\(metricKey)): \(error)")
        }
    }

    private func deliverMetricPayloadToDelegate(_ payload: [String: Any]) {
        guard let delegate = HumangoHealthPlugin.delegate else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8),
              let fetchedAt = payload["fetchedAt"] as? String,
              let metricType = payload["metricType"] as? String else {
            print("📊 [Quantity metrics observer] Delegate delivery skipped — JSON serialization failed")
            return
        }
        DispatchQueue.main.async {
            delegate.onHealthMetricSamplesReady(json: jsonString, metricType: metricType, fetchedAt: fetchedAt)
        }
        print("📊 [Quantity metrics observer] Delegated batch — metricType=\(metricType), count=\(payload["sampleCount"] ?? 0)")
    }

    private func convertToDict(_ sample: HKQuantitySample, unit: HKUnit, unitLabel: String) -> [String: Any] {
        let value = sample.quantity.doubleValue(for: unit)
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
            dict["device"] = deviceDict
        }
        if let metadata = sample.metadata, !metadata.isEmpty {
            var meta: [String: Any] = [:]
            for (k, v) in metadata {
                if let s = v as? String { meta[k] = s }
                else if let n = v as? NSNumber { meta[k] = n }
                else if let d = v as? Date { meta[k] = isoFormatter.string(from: d) }
                else { meta[k] = String(describing: v) }
            }
            dict["metadata"] = meta
        }
        return dict
    }
}
