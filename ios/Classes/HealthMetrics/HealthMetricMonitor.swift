//
//  HealthMetricMonitor.swift
//  humango_health
//
//  Per-metric HealthKit observer that mirrors the WorkoutService/RouteService pattern.
//  Foreground: HKAnchoredObjectQueryDescriptor live stream (iOS 17+).
//  Background: HKObserverQuery + enableBackgroundDelivery (immediate frequency).
//
//  On every HealthKit notification (foreground or background) the monitor fetches
//  the current day's samples (midnight → now) and delivers them via
//  HumangoHealthPlugin.delegate?.onHealthMetricReady(payload:metricType:).
//
//  completion() is called ONLY after the full async fetch → delegate pipeline
//  finishes, keeping iOS alive for background deliveries.
//

import Foundation
import HealthKit

@available(iOS 17.0, *)
final class HealthMetricMonitor: AppLifecycleObserver {

    // MARK: - Properties

    let metricType: HealthMetricType

    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private var anchor: HKQueryAnchor?
    private var updateTask: Task<Void, Never>?
    private var observer: HKObserverQuery?
    private var isStarted = false

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Init / Deinit

    init(metricType: HealthMetricType) {
        self.metricType = metricType
        AppLifecycleManager.shared.addObserver(self)
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): initialized — lifecycle observer registered")
    }

    deinit {
        AppLifecycleManager.shared.removeObserver(self)
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): deallocated")
    }

    // MARK: - Public API

    /// Start monitoring. Chooses foreground (live stream) vs background (observer)
    /// based on the current app state so a cold background relaunch works correctly.
    func start() {
        isStarted = true
        if AppLifecycleManager.shared.isInForeground {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): start → foreground mode")
            SleepRemoteLogger.log(.info, step: "start", message: "starting in foreground mode", context: [
                "class": "HealthMetricMonitor",
                "metricType": metricType.key,
            ], subsystem: "HealthMetrics")
            startLiveUpdates()
        } else {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): start → background mode (cold relaunch)")
            SleepRemoteLogger.log(.info, step: "start", message: "starting in background mode (cold relaunch)", context: [
                "class": "HealthMetricMonitor",
                "metricType": metricType.key,
            ], subsystem: "HealthMetrics")
            startBackgroundMonitoring()
        }
    }

    /// Stop both live and background paths and remove this instance from the
    /// lifecycle observer list. Call before removing from the registry.
    func invalidate() {
        isStarted = false
        stopLiveUpdates()
        stopBackgroundMonitoring()
        AppLifecycleManager.shared.removeObserver(self)
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): invalidated")
        SleepRemoteLogger.log(.info, step: "invalidate", message: "monitor invalidated", context: [
            "class": "HealthMetricMonitor",
            "metricType": metricType.key,
        ], subsystem: "HealthMetrics")
    }

    // MARK: - AppLifecycleObserver

    func appDidEnterForeground() {
        guard isStarted else { return }
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): appDidEnterForeground — switching to foreground mode")
        SleepRemoteLogger.log(.info, step: "lifecycle", message: "appDidEnterForeground", context: [
            "class": "HealthMetricMonitor",
            "metricType": metricType.key,
        ], subsystem: "HealthMetrics")
        enterForegroundMode()
    }

    func appDidEnterBackground() {
        guard isStarted else { return }
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): appDidEnterBackground — switching to background mode")
        SleepRemoteLogger.log(.info, step: "lifecycle", message: "appDidEnterBackground", context: [
            "class": "HealthMetricMonitor",
            "metricType": metricType.key,
        ], subsystem: "HealthMetrics")
        enterBackgroundMode()
    }

    // MARK: - Foreground / Background switches

    func enterForegroundMode() {
        stopBackgroundMonitoring()
        startLiveUpdates()
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): entered FOREGROUND mode")
    }

    func enterBackgroundMode() {
        stopLiveUpdates()
        startBackgroundMonitoring()
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): entered BACKGROUND mode")
    }

    // MARK: - Live Updates (Foreground — HKAnchoredObjectQueryDescriptor stream)

    func startLiveUpdates() {
        guard let quantityType = metricType.quantityType else {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): startLiveUpdates skipped — quantityType unavailable")
            return
        }

        let startOfToday = Calendar.current.startOfDay(for: Date())
        let livePredicate = HKQuery.predicateForSamples(
            withStart: startOfToday,
            end: nil,
            options: [.strictStartDate]
        )

        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: quantityType, predicate: livePredicate)],
            anchor: anchor
        )
        let stream = desc.results(for: healthStore)

        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self = self else { return }
            debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): live stream started — watching from \(startOfToday)")
            do {
                for try await update in stream {
                    self.anchor = update.newAnchor
                    let count = update.addedSamples.count
                    debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): live stream update — \(count) new sample(s), fetching today's payload")
                    SleepRemoteLogger.log(.info, step: "liveUpdate", message: "live stream update received", context: [
                        "class": "HealthMetricMonitor",
                        "metricType": self.metricType.key,
                        "newSamples": count,
                    ], subsystem: "HealthMetrics")
                    await self.fetchAndDeliverCurrentDay()
                }
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): live stream ended normally")
            } catch {
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): live stream error — \(error)")
                SleepRemoteLogger.log(.error, step: "liveUpdate", message: "live stream error", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": self.metricType.key,
                    "error": "\(error)",
                ], subsystem: "HealthMetrics")
            }
        }

        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): live updates started")
    }

    func stopLiveUpdates() {
        guard updateTask != nil else { return }
        updateTask?.cancel()
        updateTask = nil
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): live updates stopped")
    }

    // MARK: - Background Monitoring (HKObserverQuery)

    func startBackgroundMonitoring() {
        guard let quantityType = metricType.quantityType else {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): startBackgroundMonitoring skipped — quantityType unavailable")
            return
        }

        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): startBackgroundMonitoring — enabling background delivery + installing observer")
        SleepRemoteLogger.log(.info, step: "startBackgroundMonitoring", message: "registering background delivery + observer", context: [
            "class": "HealthMetricMonitor",
            "metricType": metricType.key,
        ], subsystem: "HealthMetrics")

        Task {
            do {
                try await healthStore.enableBackgroundDelivery(for: quantityType, frequency: .immediate)
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): enableBackgroundDelivery — success (immediate)")
                SleepRemoteLogger.log(.info, step: "startBackgroundMonitoring", message: "background delivery enabled", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": self.metricType.key,
                ], subsystem: "HealthMetrics")
            } catch {
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): enableBackgroundDelivery failed — \(error)")
                SleepRemoteLogger.log(.error, step: "startBackgroundMonitoring", message: "enableBackgroundDelivery failed", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": self.metricType.key,
                    "error": "\(error)",
                ], subsystem: "HealthMetrics")
            }
        }

        observer = HKObserverQuery(sampleType: quantityType, predicate: nil) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            // NOTE: Do NOT use `defer { completion() }` here.
            // completion() must be called AFTER the full async fetch → delegate
            // pipeline finishes so iOS does not suspend the app mid-delivery.

            let fireTime = Date()
            if let error = error {
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): background observer error at \(fireTime) — \(error)")
                SleepRemoteLogger.log(.error, step: "observer", message: "observer error", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": self.metricType.key,
                    "error": "\(error)",
                ], subsystem: "HealthMetrics")
                completion()
                return
            }

            debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): background observer fired at \(fireTime) — starting fetch pipeline")
            SleepRemoteLogger.log(.info, step: "observer_fired", message: "background observer fired — starting fetch", context: [
                "class": "HealthMetricMonitor",
                "metricType": self.metricType.key,
                "fireTime": ISO8601DateFormatter().string(from: fireTime),
            ], subsystem: "HealthMetrics")

            Task {
                await self.fetchAndDeliverCurrentDay()
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): background observer pipeline complete — signalling completion()")
                SleepRemoteLogger.log(.info, step: "observer_fired", message: "pipeline complete — signalling completion", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": self.metricType.key,
                ], subsystem: "HealthMetrics")
                // Signal HealthKit AFTER all async work (fetch + delegate await) completes
                // so iOS keeps the app alive for the full pipeline.
                completion()
            }
        }

        if let q = observer {
            healthStore.execute(q)
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): background observer installed and executing")
        }
    }

    func stopBackgroundMonitoring() {
        if let q = observer {
            healthStore.stop(q)
            observer = nil
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): background observer removed")
        }
        guard let quantityType = metricType.quantityType else { return }
        healthStore.disableBackgroundDelivery(for: quantityType) { ok, err in
            if let err {
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): disableBackgroundDelivery error — \(err)")
            } else {
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): disableBackgroundDelivery — ok=\(ok)")
            }
        }
    }

    // MARK: - Fetch current day's samples and deliver to delegate

    /// Fetches all samples from midnight today to now using HKAnchoredObjectQueryDescriptor
    /// (snapshot mode), updates the local anchor, builds the payload dict, and calls
    /// HumangoHealthPlugin.delegate?.onHealthMetricReady(payload:metricType:).
    ///
    /// All numeric values are raw Double — no rounding applied.
    /// All dates are ISO 8601 with fractional seconds.
    private func fetchAndDeliverCurrentDay() async {
        guard let quantityType = metricType.quantityType else {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): fetchAndDeliverCurrentDay skipped — quantityType unavailable")
            return
        }

        let startOfToday = Calendar.current.startOfDay(for: Date())
        let endDate = Date()

        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): fetchAndDeliverCurrentDay — querying \(startOfToday) → \(endDate)")
        SleepRemoteLogger.log(.info, step: "fetchAndDeliverCurrentDay", message: "fetching current-day samples", context: [
            "class": "HealthMetricMonitor",
            "metricType": metricType.key,
            "startOfToday": isoFormatter.string(from: startOfToday),
            "endDate": isoFormatter.string(from: endDate),
        ], subsystem: "HealthMetrics")

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfToday,
            end: endDate,
            options: [.strictStartDate]
        )

        let desc = HKAnchoredObjectQueryDescriptor(
            predicates: [.quantitySample(type: quantityType, predicate: predicate)],
            anchor: anchor
        )

        do {
            let result = try await desc.result(for: healthStore)
            anchor = result.newAnchor

            let samples = result.addedSamples
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): fetchAndDeliverCurrentDay — found \(samples.count) sample(s)")

            let unit = metricType.unit
            let unitLabel = metricType.unitLabel

            var sampleDicts: [[String: Any]] = []
            var sum: Double = 0
            var minVal: Double = Double.greatestFiniteMagnitude
            var maxVal: Double = -Double.greatestFiniteMagnitude

            for sample in samples {
                // Raw doubleValue — no rounding
                let value = sample.quantity.doubleValue(for: unit)
                sampleDicts.append(buildSampleDict(sample, value: value, unitLabel: unitLabel))
                sum += value
                if value < minVal { minVal = value }
                if value > maxVal { maxVal = value }
            }

            let count = samples.count
            let average: Double = count > 0 ? sum / Double(count) : 0
            if count == 0 { minVal = 0; maxVal = 0 }

            // Latest = last sample (samples are in ascending start-date order by default)
            let latestSample: [String: Any]? = sampleDicts.last

            let payload: [String: Any] = [
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
                "fetchedFrom": isoFormatter.string(from: startOfToday),
                "fetchedTo": isoFormatter.string(from: endDate),
            ]

            if let delegate = HumangoHealthPlugin.delegate {
                debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): calling delegate.onHealthMetricReady — sampleCount=\(count)")
                SleepRemoteLogger.log(.info, step: "fetchAndDeliverCurrentDay", message: "calling delegate.onHealthMetricReady", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": metricType.key,
                    "sampleCount": count,
                ], subsystem: "HealthMetrics")
                await delegate.onHealthMetricReady(payload: payload, metricType: metricType.key)
                debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): delegate.onHealthMetricReady returned")
                SleepRemoteLogger.log(.info, step: "fetchAndDeliverCurrentDay", message: "delegate.onHealthMetricReady returned", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": metricType.key,
                ], subsystem: "HealthMetrics")
            } else {
                debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): delegate is nil — payload not delivered")
                SleepRemoteLogger.log(.warn, step: "fetchAndDeliverCurrentDay", message: "delegate nil — payload not delivered", context: [
                    "class": "HealthMetricMonitor",
                    "metricType": metricType.key,
                ], subsystem: "HealthMetrics")
            }
        } catch {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): fetchAndDeliverCurrentDay error — \(error)")
            SleepRemoteLogger.log(.error, step: "fetchAndDeliverCurrentDay", message: "fetch error", context: [
                "class": "HealthMetricMonitor",
                "metricType": metricType.key,
                "error": "\(error)",
            ], subsystem: "HealthMetrics")
        }
    }

    // MARK: - Sample → Dictionary helper

    private func buildSampleDict(
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
}
