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
        // NOTE: Do NOT call AppLifecycleManager.removeObserver(self) here.
        // removeObserver dispatches an async barrier block that strongly captures the
        // observer argument, extending its lifetime past deinit and causing a
        // "deallocated with non-zero retain count" dangling-reference warning.
        // invalidate() already removes the observer synchronously; NSHashTable.weakObjects()
        // automatically clears the entry when the object is deallocated.
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): deallocated")
    }

    // MARK: - Public API

    /// Start monitoring. Chooses foreground (live stream) vs background (observer)
    /// based on the current app state so a cold background relaunch works correctly.
    func start() {
        isStarted = true
        if AppLifecycleManager.shared.isInForeground {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): start → foreground mode")
            // Pre-register background delivery while still in the foreground so HealthKit
            // persists the wake-up registration before iOS can suspend the process.
            if let quantityType = metricType.quantityType {
                let key = metricType.key
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.healthStore.enableBackgroundDelivery(for: quantityType, frequency: .immediate)
                        debugPrint("[Humango] HealthMetricMonitor(\(key)): start — pre-registered background delivery (immediate)")
                    } catch {
                        debugPrint("[Humango] HealthMetricMonitor(\(key)): start — pre-register background delivery failed: \(error)")
                    }
                }
            }
            startLiveUpdates()
        } else {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): start → background mode (cold relaunch)")
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
    }

    // MARK: - AppLifecycleObserver

    func appDidEnterForeground() {
        guard isStarted else { return }
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): appDidEnterForeground — switching to foreground mode")
        enterForegroundMode()
    }

    func appDidEnterBackground() {
        guard isStarted else { return }
        debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): appDidEnterBackground — switching to background mode")
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
                    await self.fetchAndDeliverCurrentDay()
                }
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): live stream ended normally")
            } catch {
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): live stream error — \(error)")
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

        // Capture key by value so the Task does not hold a strong reference to self
        // after invalidate() has already released it from the monitors registry.
        let key = metricType.key
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.healthStore.enableBackgroundDelivery(for: quantityType, frequency: .immediate)
                debugPrint("[Humango] HealthMetricMonitor(\(key)): enableBackgroundDelivery — success (immediate)")
            } catch {
                debugPrint("[Humango] HealthMetricMonitor(\(key)): enableBackgroundDelivery failed — \(error)")
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
                completion()
                return
            }

            debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): background observer fired at \(fireTime) — starting fetch pipeline")

            Task {
                await self.fetchAndDeliverCurrentDay()
                debugPrint("[Humango] HealthMetricMonitor(\(self.metricType.key)): background observer pipeline complete — signalling completion()")
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
        // NOTE: Do NOT call disableBackgroundDelivery here.
        // disableBackgroundDelivery globally unregisters the HealthKit wake-up for this
        // type. Calling it on every foreground transition or monitor stop would prevent
        // iOS from waking the app for background deliveries entirely.
        // Background delivery stays enabled for the lifetime of the app install.
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
                await delegate.onHealthMetricReady(payload: payload, metricType: metricType.key)
                debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): delegate.onHealthMetricReady returned")
            } else {
                debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): delegate is nil — payload not delivered")
            }
        } catch {
            debugPrint("[Humango] HealthMetricMonitor(\(metricType.key)): fetchAndDeliverCurrentDay error — \(error)")
        }
    }

    // MARK: - Sample → Dictionary helper

    private func buildSampleDict(
        _ sample: HKQuantitySample,
        value: Double,
        unitLabel: String
    ) -> [String: Any] {
        let bundle = sample.sourceRevision.source.bundleIdentifier
        var dict: [String: Any] = [
            "uuid": sample.uuid.uuidString,
            "value": value,
            "unit": unitLabel,
            "startDate": isoFormatter.string(from: sample.startDate),
            "endDate": isoFormatter.string(from: sample.endDate),
            "sourceName": HealthKitConverter.normalizedSourceName(name: sample.sourceRevision.source.name, bundle: bundle),
            "sourceBundle": bundle,
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
