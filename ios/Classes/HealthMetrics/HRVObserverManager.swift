//
//  HRVObserverManager.swift
//  humango_health
//
//  Observes HealthKit quantity samples (HRV, heart rate, resting HR, body composition, etc.)
//  and delivers new data to the host app via HumangoHealthDataDelegate.
//
//  Foreground:            HKAnchoredObjectQueryDescriptor — anchor-based async stream per type.
//                         On each batch of added samples, fetches the full lookback window and
//                         delivers to the delegate.
//  Background/suspended:  HKObserverQuery — iOS wakes the app via enableBackgroundDelivery;
//                         on each fire, fetches the lookback window and delivers to the delegate.
//
//  No EventChannel / Flutter stream is used. All delivery is through the delegate.
//

import Foundation
import HealthKit

// MARK: - UserDefaults Keys

private struct HRVObserverKeys {
    static let monitoringEnabled    = "com.humango.health.hrvMonitoringEnabled"
    /// Legacy keys — cleared on start to avoid stale state.
    static let legacyPendingUpdates = "com.humango.health.hrvPendingUpdates"
    static let legacyLastAnchor     = "com.humango.health.hrvLastAnchor"
}

// MARK: - HRVObserverManager

/// Manages HKAnchoredObjectQueryDescriptor (foreground) and HKObserverQuery (background)
/// for all `HealthMetricType` cases. Switches modes automatically via `AppLifecycleObserver`.
public class HRVObserverManager: NSObject, AppLifecycleObserver {
    static let shared = HRVObserverManager()

    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - State

    /// HKObserverQuery instances, keyed by metric type — active in background mode.
    private var observerQueries: [HealthMetricType: HKObserverQuery] = [:]

    /// Async streaming tasks (HKAnchoredObjectQueryDescriptor), keyed by metric type — active in foreground mode.
    private var liveUpdateTasks: [HealthMetricType: Task<Void, Never>] = [:]

    /// Anchors per type — preserved across foreground/background switches so the
    /// descriptor resumes from where it left off.
    private var anchors: [HealthMetricType: HKQueryAnchor] = [:]

    private var isMonitoring           = false
    private var isLiveStreaming         = false
    private var isBackgroundMonitoring  = false

    private override init() {
        super.init()
        AppLifecycleManager.shared.addObserver(self)
    }

    deinit {
        AppLifecycleManager.shared.removeObserver(self)
    }

    // MARK: - Public API

    /// Whether monitoring has been started and persisted for auto-restart on next launch.
    var isMonitoringEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: HRVObserverKeys.monitoringEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: HRVObserverKeys.monitoringEnabled)
            UserDefaults.standard.synchronize()
        }
    }

    /// Start observing all `HealthMetricType` cases and enable background delivery for each.
    /// Selects foreground (descriptor) or background (observer) mode based on current app state.
    func startMonitoring() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            print("📊 [Quantity metrics observer] startMonitoring ignored — user not logged in")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            print("📊 [Quantity metrics observer] HealthKit not available")
            return
        }
        guard !isMonitoring else {
            print("📊 [Quantity metrics observer] Already monitoring")
            return
        }

        // Clear legacy keys that are no longer used.
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyPendingUpdates)
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyLastAnchor)

        isMonitoring = true
        isMonitoringEnabled = true
        SleepRemoteLogger.log(.info, step: "startMonitoring", message: "Health metrics monitoring started", context: ["class": "HRVObserverManager", "method": "startMonitoring"], subsystem: "HealthMetricsObserver")

        // Enable background delivery for every type first.
        Task {
            for type in HealthMetricType.allCases {
                guard let qType = type.quantityType else { continue }
                do {
                    try await healthStore.enableBackgroundDelivery(for: qType, frequency: .immediate)
                    print("📊 [Quantity metrics observer] Enabled background delivery for \(type.key)")
                    SleepRemoteLogger.log(.info, step: "enableBackgroundDelivery", message: "Enabled for \(type.key)", context: ["class": "HRVObserverManager", "method": "startMonitoring", "metricType": type.key], subsystem: "HealthMetricsObserver")
                } catch {
                    print("📊 [Quantity metrics observer] enableBackgroundDelivery failed (\(type.key)): \(error)")
                    SleepRemoteLogger.log(.error, step: "enableBackgroundDelivery", message: "Failed for \(type.key): \(error.localizedDescription)", context: ["class": "HRVObserverManager", "method": "startMonitoring", "metricType": type.key], subsystem: "HealthMetricsObserver")
                }
            }
        }

        // Choose the appropriate monitoring mode for the current app state.
        if AppLifecycleManager.shared.isInForeground {
            startLiveUpdates()
        } else {
            startBackgroundMonitoring()
        }
    }

    /// Stop all observers, disable background delivery, and clear persisted preference.
    func stopMonitoring() {
        stopLiveUpdates()
        stopBackgroundMonitoring()

        for type in HealthMetricType.allCases {
            guard let qType = type.quantityType else { continue }
            healthStore.disableBackgroundDelivery(for: qType) { success, error in
                if let error = error {
                    print("📊 [Quantity metrics observer] disableBackgroundDelivery error (\(type.key)): \(error)")
                } else if success {
                    print("📊 [Quantity metrics observer] Disabled background delivery for \(type.key)")
                }
            }
        }

        isMonitoring = false
        isMonitoringEnabled = false
        print("📊 [Quantity metrics observer] Stopped all metric monitoring")
    }

    /// Full reset — stops monitoring and clears all cached state (e.g. on logout).
    func stopAndClearAll() {
        stopMonitoring()
        anchors.removeAll()
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyPendingUpdates)
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.legacyLastAnchor)
        UserDefaults.standard.synchronize()
        print("📊 [Quantity metrics observer] Cleared all state")
    }

    /// Legacy API: pending batches are no longer stored in UserDefaults.
    /// Background delivery is exclusively via `HumangoHealthDataDelegate.onHealthMetricSamplesReady`.
    func retrievePendingHRVUpdates() -> [[String: Any]] { [] }

    /// Auto-start on app launch / login whenever the user is logged in and a delegate is set.
    /// Matches the same unconditional pattern used by SleepDataManager and WorkoutServiceChannel
    /// — no persisted "monitoring enabled" flag required.
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            print("📊 [Quantity metrics observer] Auto-start skipped — user not logged in")
            return
        }
        guard HumangoHealthPlugin.delegate != nil else {
            print("📊 [Quantity metrics observer] Auto-start skipped — delegate not set")
            return
        }
        guard !isMonitoring else {
            print("📊 [Quantity metrics observer] Auto-start skipped — already monitoring")
            return
        }
        startMonitoring()
        print("📊 [Quantity metrics observer] Auto-started")
    }

    // MARK: - AppLifecycleObserver

    public func appDidEnterForeground() {
        guard isMonitoring else { return }
        switchToForegroundMode()
    }

    public func appDidEnterBackground() {
        guard isMonitoring else { return }
        switchToBackgroundMode()
    }

    // MARK: - Mode Switching

    private func switchToForegroundMode() {
        stopBackgroundMonitoring()
        startLiveUpdates()
        print("📊 [Quantity metrics observer] → foreground mode")
        SleepRemoteLogger.log(.info, step: "modeSwitch", message: "Switched to foreground mode", context: ["class": "HRVObserverManager", "method": "switchToForegroundMode"], subsystem: "HealthMetricsObserver")
    }

    private func switchToBackgroundMode() {
        stopLiveUpdates()
        startBackgroundMonitoring()
        print("📊 [Quantity metrics observer] → background mode")
        SleepRemoteLogger.log(.info, step: "modeSwitch", message: "Switched to background mode", context: ["class": "HRVObserverManager", "method": "switchToBackgroundMode"], subsystem: "HealthMetricsObserver")
    }

    // MARK: - Foreground: HKAnchoredObjectQueryDescriptor

    /// Starts one `HKAnchoredObjectQueryDescriptor` async stream per `HealthMetricType`.
    /// When new samples arrive the full lookback window is fetched and delivered to the delegate.
    private func startLiveUpdates() {
        guard !isLiveStreaming else { return }
        isLiveStreaming = true

        for type in HealthMetricType.allCases {
            guard let quantityType = type.quantityType else { continue }

            let predicate = HKQuery.predicateForSamples(withStart: nil, end: nil, options: .strictStartDate)
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [HKSamplePredicate<HKQuantitySample>.quantitySample(
                    type: quantityType,
                    predicate: predicate
                )],
                anchor: anchors[type]
            )

            let stream        = descriptor.results(for: healthStore)
            let capturedType  = type

            let task = Task { [weak self] in
                guard let self = self else { return }
                do {
                    for try await update in stream {
                        self.anchors[capturedType] = update.newAnchor
                        guard !update.addedSamples.isEmpty else { continue }
                        print("📊 [Quantity metrics observer] foreground: \(update.addedSamples.count) new \(capturedType.key) sample(s)")
                        SleepRemoteLogger.log(.info, step: "foregroundUpdate", message: "New samples received for \(capturedType.key)", context: ["class": "HRVObserverManager", "method": "startLiveUpdates", "metricType": capturedType.key, "count": update.addedSamples.count], subsystem: "HealthMetricsObserver")
                        await self.fetchAndDeliverUpdates(metricType: capturedType)
                    }
                } catch {
                    // Task cancellation is expected during mode switches — only log real errors.
                    if !Task.isCancelled {
                        print("📊 [Quantity metrics observer] foreground stream error (\(capturedType.key)): \(error)")
                        SleepRemoteLogger.log(.error, step: "foregroundStreamError", message: "Stream error for \(capturedType.key): \(error.localizedDescription)", context: ["class": "HRVObserverManager", "method": "startLiveUpdates", "metricType": capturedType.key], subsystem: "HealthMetricsObserver")
                    }
                }
            }
            liveUpdateTasks[type] = task
        }

        print("📊 [Quantity metrics observer] Started foreground descriptor streams (\(HealthMetricType.allCases.count) type(s))")

        // Deliver an initial snapshot for all types when entering foreground.
        Task { [weak self] in
            guard let self = self else { return }
            for type in HealthMetricType.allCases {
                await self.fetchAndDeliverUpdates(metricType: type)
            }
        }
    }

    private func stopLiveUpdates() {
        liveUpdateTasks.values.forEach { $0.cancel() }
        liveUpdateTasks.removeAll()
        isLiveStreaming = false
        print("📊 [Quantity metrics observer] Stopped foreground descriptor streams")
    }

    // MARK: - Background: HKObserverQuery

    /// Starts one `HKObserverQuery` per `HealthMetricType`.
    /// iOS wakes the app when new data arrives; the full lookback window is fetched and delivered.
    private func startBackgroundMonitoring() {
        guard !isBackgroundMonitoring else { return }
        isBackgroundMonitoring = true

        let predicate = HKQuery.predicateForSamples(withStart: nil, end: nil, options: .strictStartDate)

        for type in HealthMetricType.allCases {
            guard let quantityType = type.quantityType else {
                print("📊 [Quantity metrics observer] Type unavailable: \(type.key)")
                continue
            }
            let capturedType = type

            let query = HKObserverQuery(sampleType: quantityType, predicate: predicate) { [weak self] _, completion, error in
                guard let self = self else { completion(); return }
                // NOTE: Do NOT use `defer { completion() }`.
                // completion() must be called AFTER fetchAndDeliverUpdates so iOS keeps the
                // app alive for the full fetch → delegate pipeline.
                if let error = error {
                    print("📊 [Quantity metrics observer] Observer error (\(capturedType.key)): \(error)")
                    SleepRemoteLogger.log(.error, step: "observerFired", message: "Observer error for \(capturedType.key): \(error.localizedDescription)", context: ["class": "HRVObserverManager", "method": "startBackgroundMonitoring", "metricType": capturedType.key], subsystem: "HealthMetricsObserver")
                    completion()
                    return
                }
                print("📊 [Quantity metrics observer] HealthKit changed — \(capturedType.key)")
                SleepRemoteLogger.log(.info, step: "observerFired", message: "Background observer fired for \(capturedType.key)", context: ["class": "HRVObserverManager", "method": "startBackgroundMonitoring", "metricType": capturedType.key], subsystem: "HealthMetricsObserver")
                Task {
                    await self.fetchAndDeliverUpdates(metricType: capturedType)
                    completion()
                }
            }
            healthStore.execute(query)
            observerQueries[type] = query
        }

        print("📊 [Quantity metrics observer] Started \(observerQueries.count) background observer(s)")
    }

    private func stopBackgroundMonitoring() {
        observerQueries.values.forEach { healthStore.stop($0) }
        observerQueries.removeAll()
        isBackgroundMonitoring = false
        print("📊 [Quantity metrics observer] Stopped background observers")
    }

    // MARK: - Fetch and Deliver

    private func fetchAndDeliverUpdates(metricType: HealthMetricType) async {
        guard let quantityType = metricType.quantityType else { return }

        // HRV: query the full current calendar day in local time (00:00:00 → start of tomorrow)
        // so the daily average reflects every reading recorded today, regardless of when the
        // observer fires. All other types keep their configured lookback window.
        let startDate: Date
        let endDate: Date
        if metricType == .heartRateVariabilitySDNN {
            let cal   = Calendar.current
            let now   = Date()
            startDate = cal.startOfDay(for: now)
            endDate   = cal.date(byAdding: .day, value: 1, to: startDate) ?? now
        } else {
            endDate   = Date()
            startDate = Calendar.current.date(byAdding: .day, value: -metricType.observerLookbackDays, to: endDate) ?? endDate
        }

        let predicate      = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        do {
            let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKQuantitySample], Error>) in
                let query = HKSampleQuery(
                    sampleType: quantityType,
                    predicate: predicate,
                    limit: metricType.observerSampleLimit,
                    sortDescriptors: [sortDescriptor]
                ) { _, results, error in
                    if let error = error { cont.resume(throwing: error); return }
                    cont.resume(returning: (results as? [HKQuantitySample]) ?? [])
                }
                healthStore.execute(query)
            }

            let sampleDicts = samples.map { convertToDict($0, unit: metricType.unit, unitLabel: metricType.unitLabel) }
            let fetchedAt   = isoFormatter.string(from: Date())

            var payload: [String: Any] = [
                "metricType": metricType.key,
                "unit":        metricType.unitLabel,
                "samples":     sampleDicts,
                "sampleCount": sampleDicts.count,
                "fetchedAt":   fetchedAt,
            ]

            // HRV only: compute the unrounded daily average across all samples for today.
            // No rounding or truncation is applied at any step — raw Double arithmetic only.
            if metricType == .heartRateVariabilitySDNN, !samples.isEmpty {
                let sum: Double = samples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: metricType.unit) }
                let dailyAverage: Double = sum / Double(samples.count)
                payload["dailyAverage"] = dailyAverage
                payload["windowStart"]  = isoFormatter.string(from: startDate)
                payload["windowEnd"]    = isoFormatter.string(from: endDate)
                print("📊 [Quantity metrics observer] HRV daily average: \(dailyAverage) ms from \(samples.count) sample(s) [\(isoFormatter.string(from: startDate)) → \(isoFormatter.string(from: endDate))]")
            }

            SleepRemoteLogger.log(.info, step: "fetchComplete", message: "Fetched \(samples.count) \(metricType.key) sample(s)", context: ["class": "HRVObserverManager", "method": "fetchAndDeliverUpdates", "metricType": metricType.key, "count": samples.count, "samples": sampleDicts], subsystem: "HealthMetricsObserver")

            await deliverMetricPayloadToDelegate(payload, metricType: metricType, fetchedAt: fetchedAt)

        } catch {
            print("📊 [Quantity metrics observer] Fetch error (\(metricType.key)): \(error)")
            SleepRemoteLogger.log(.error, step: "fetchError", message: "Fetch error for \(metricType.key): \(error.localizedDescription)", context: ["class": "HRVObserverManager", "method": "fetchAndDeliverUpdates", "metricType": metricType.key], subsystem: "HealthMetricsObserver")
        }
    }

    // `async` so `fetchAndDeliverUpdates` can `await` it, keeping the full
    // pipeline synchronous with the HealthKit completion() handler.
    private func deliverMetricPayloadToDelegate(
        _ payload: [String: Any],
        metricType: HealthMetricType,
        fetchedAt: String
    ) async {
        guard let delegate = HumangoHealthPlugin.delegate else { return }
        guard
            let jsonData   = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            print("📊 [Quantity metrics observer] Delegate delivery skipped — JSON serialization failed")
            SleepRemoteLogger.log(.error, step: "deliverDelegate", message: "JSON serialization failed for \(metricType.key)", context: ["class": "HRVObserverManager", "method": "deliverMetricPayloadToDelegate", "metricType": metricType.key], subsystem: "HealthMetricsObserver")
            return
        }
        await delegate.onHealthMetricSamplesReady(json: jsonString, metricType: metricType, fetchedAt: fetchedAt)
        print("📊 [Quantity metrics observer] Delegated batch — metricType=\(metricType.key), count=\(payload["sampleCount"] ?? 0)")
        SleepRemoteLogger.log(.info, step: "deliverDelegate", message: "Delivered to delegate: \(metricType.key), count=\(payload["sampleCount"] ?? 0)", context: ["class": "HRVObserverManager", "method": "deliverMetricPayloadToDelegate", "metricType": metricType.key, "count": payload["sampleCount"] as? Int ?? 0, "fetchedAt": fetchedAt, "payload": payload], subsystem: "HealthMetricsObserver")
    }

    // MARK: - Sample → Dictionary

    private func convertToDict(_ sample: HKQuantitySample, unit: HKUnit, unitLabel: String) -> [String: Any] {
        let value = sample.quantity.doubleValue(for: unit)
        var dict: [String: Any] = [
            "uuid":         sample.uuid.uuidString,
            "value":        value,
            "unit":         unitLabel,
            "startDate":    isoFormatter.string(from: sample.startDate),
            "endDate":      isoFormatter.string(from: sample.endDate),
            "sourceName":   sample.sourceRevision.source.name,
            "sourceBundle": sample.sourceRevision.source.bundleIdentifier,
        ]
        if let device = sample.device {
            var deviceDict: [String: Any] = [:]
            if let name         = device.name         { deviceDict["name"]         = name }
            if let model        = device.model        { deviceDict["model"]        = model }
            if let manufacturer = device.manufacturer { deviceDict["manufacturer"] = manufacturer }
            dict["device"] = deviceDict
        }
        if let metadata = sample.metadata, !metadata.isEmpty {
            var meta: [String: Any] = [:]
            for (k, v) in metadata {
                if let s = v as? String        { meta[k] = s }
                else if let n = v as? NSNumber { meta[k] = n }
                else if let d = v as? Date     { meta[k] = isoFormatter.string(from: d) }
                else                           { meta[k] = String(describing: v) }
            }
            dict["metadata"] = meta
        }
        return dict
    }
}
