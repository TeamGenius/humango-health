//
//  HRVObserverManager.swift
//  humango_health
//
//  Observes HealthKit HRV (heartRateVariabilitySDNN) and automatically reads new data
//  when it is added. Works in foreground, background, and when app is suspended
//  (iOS wakes the app briefly via enableBackgroundDelivery).
//

import Foundation
import HealthKit
import Flutter

// MARK: - UserDefaults Keys

private struct HRVObserverKeys {
    static let monitoringEnabled = "com.humango.health.hrvMonitoringEnabled"
    static let pendingUpdates = "com.humango.health.hrvPendingUpdates"
    static let lastProcessedAnchor = "com.humango.health.hrvLastAnchor"
}

// MARK: - HRVObserverManager

/// Manages HKObserverQuery and background delivery for HRV so the app automatically
/// reads HRV when HealthKit is updated (foreground, background, suspended).
public class HRVObserverManager: NSObject, AppLifecycleObserver {
    static let shared = HRVObserverManager()

    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private var observerQuery: HKObserverQuery?
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

    /// Whether HRV monitoring has been started and is persisted (for auto-start on launch).
    var isMonitoringEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: HRVObserverKeys.monitoringEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: HRVObserverKeys.monitoringEnabled); UserDefaults.standard.synchronize() }
    }

    /// Attach Flutter event sink to stream HRV updates when in foreground.
    func attachEventSink(_ sink: FlutterEventSink?) {
        self.eventSink = sink
    }

    /// Start observing HRV. Registers HKObserverQuery and enables background delivery.
    func startMonitoring() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            print("📊 [HRV Observer] startMonitoring ignored — user not logged in")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            print("📊 [HRV Observer] HealthKit not available")
            return
        }

        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            print("📊 [HRV Observer] HRV type not available")
            return
        }

        if isMonitoring {
            print("📊 [HRV Observer] Already monitoring")
            return
        }

        isMonitoring = true
        isMonitoringEnabled = true

        // Enable background delivery so iOS wakes the app when new HRV is written
        Task {
            do {
                try await healthStore.enableBackgroundDelivery(for: hrvType, frequency: .immediate)
                print("📊 [HRV Observer] Enabled background delivery for HRV (immediate)")
            } catch {
                print("📊 [HRV Observer] enableBackgroundDelivery failed: \(error)")
            }
        }

        let predicate = HKQuery.predicateForSamples(withStart: nil, end: nil, options: .strictStartDate)
        observerQuery = HKObserverQuery(sampleType: hrvType, predicate: predicate) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            defer { completion() }

            if let error = error {
                print("📊 [HRV Observer] Observer error: \(error)")
                return
            }

            print("📊 [HRV Observer] HRV data changed in HealthKit — fetching new samples")
            Task {
                await self.fetchAndDeliverHRVUpdates()
            }
        }

        if let query = observerQuery {
            healthStore.execute(query)
            print("📊 [HRV Observer] Started HRV observer (foreground + background + suspended)")
            // Sync current state immediately so UI reflects latest (including after deletions)
            Task { await self.fetchAndDeliverHRVUpdates() }
        }
    }

    /// Stop observing and disable background delivery.
    func stopMonitoring() {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }

        if let query = observerQuery {
            healthStore.stop(query)
            observerQuery = nil
        }

        healthStore.disableBackgroundDelivery(for: hrvType) { success, error in
            if let error = error {
                print("📊 [HRV Observer] disableBackgroundDelivery error: \(error)")
            } else {
                print("📊 [HRV Observer] Disabled background delivery for HRV")
            }
        }

        isMonitoring = false
        isMonitoringEnabled = false
        eventSink = nil
        print("📊 [HRV Observer] Stopped HRV monitoring")
    }

    /// Clear all state (e.g. on logout). Stops monitoring and clears pending data.
    func stopAndClearAll() {
        stopMonitoring()
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.pendingUpdates)
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.lastProcessedAnchor)
        UserDefaults.standard.synchronize()
        print("📊 [HRV Observer] Cleared all state")
    }

    /// Fetch HRV updates collected while app was in background. Returns and clears pending list.
    func retrievePendingHRVUpdates() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: HRVObserverKeys.pendingUpdates),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        UserDefaults.standard.removeObject(forKey: HRVObserverKeys.pendingUpdates)
        UserDefaults.standard.synchronize()
        if !array.isEmpty {
            print("📊 [HRV Observer] Retrieved \(array.count) pending HRV update(s)")
        }
        return array
    }

    /// Auto-start HRV monitoring on app launch when the user is logged in and monitoring was left enabled.
    /// Call from plugin register() and after login.
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            print("📊 [HRV Observer] Auto-start skipped — user not logged in")
            return
        }
        guard !isMonitoring else {
            print("📊 [HRV Observer] Auto-start skipped — already monitoring")
            return
        }
        guard isMonitoringEnabled else {
            print("📊 [HRV Observer] Auto-start skipped — HRV monitoring not enabled")
            return
        }
        startMonitoring()
        print("📊 [HRV Observer] Auto-started HRV monitoring from persisted preference")
    }

    // MARK: - AppLifecycleObserver

    public func appDidEnterForeground() {
        // Deliver any pending updates from background first
        let pending = retrievePendingHRVUpdates()
        if !pending.isEmpty, let sink = eventSink {
            for update in pending {
                DispatchQueue.main.async { sink(update) }
            }
        }
        // Always fetch latest from HealthKit so UI reflects adds/deletions done in Health app
        Task { await self.fetchAndDeliverHRVUpdates() }
    }

    public func appDidEnterBackground() {
        // No-op; observer keeps running and will store to UserDefaults when it fires in background
    }

    // MARK: - Fetch and Deliver

    /// Fetches recent HRV samples and delivers to Flutter (foreground) or stores for later (background).
    private func fetchAndDeliverHRVUpdates() async {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return }

        let unit = HKUnit.secondUnit(with: .milli)
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate) ?? endDate

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let limit = 100

        do {
            let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKQuantitySample], Error>) in
                let query = HKSampleQuery(
                    sampleType: hrvType,
                    predicate: predicate,
                    limit: limit,
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

            let sampleDicts = samples.map { convertToDict($0, unit: unit) }
            // Always deliver payload (including empty) so deletions in Health app are reflected
            let payload: [String: Any] = [
                "metricType": "heartRateVariabilitySDNN",
                "unit": "ms",
                "samples": sampleDicts,
                "sampleCount": sampleDicts.count,
                "fetchedAt": isoFormatter.string(from: Date()),
            ]

            if AppLifecycleManager.shared.isInForeground, let sink = eventSink {
                DispatchQueue.main.async { sink(payload) }
                print("📊 [HRV Observer] Delivered \(sampleDicts.count) HRV sample(s) to Flutter stream")
            } else {
                print("📊 [HRV Observer] Received HRV in background — sampleCount=\(sampleDicts.count), fetchedAt=\(payload["fetchedAt"] ?? ""), will store for later")
                storePendingUpdate(payload)
                print("📊 [HRV Observer] Stored \(sampleDicts.count) HRV sample(s) for later (background)")
            }
        } catch {
            print("📊 [HRV Observer] Fetch error: \(error)")
        }
    }

    private func convertToDict(_ sample: HKQuantitySample, unit: HKUnit) -> [String: Any] {
        let value = sample.quantity.doubleValue(for: unit)
        var dict: [String: Any] = [
            "uuid": sample.uuid.uuidString,
            "value": value,
            "unit": "ms",
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

    private func storePendingUpdate(_ payload: [String: Any]) {
        var existing: [[String: Any]] = []
        if let data = UserDefaults.standard.data(forKey: HRVObserverKeys.pendingUpdates),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existing = arr
        }
        existing.append(payload)
        if let data = try? JSONSerialization.data(withJSONObject: existing) {
            UserDefaults.standard.set(data, forKey: HRVObserverKeys.pendingUpdates)
            UserDefaults.standard.synchronize()
        }
    }
}
