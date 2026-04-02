//
//  SleepDataManager.swift
//  humango_health
//
//  Fetches and monitors sleep data from Apple HealthKit.
//
//  Background flow:
//  HKObserverQuery fires
//  └─ guard: user must be logged in
//  └─ compute 6PM window → fetch samples → calculateSleepPayload → delegate.onSleepSessionReady
//
//  Query window: 6:00 PM previous day → now  (same as old humango-mobile app)
//  Source selection: pick source with highest TOTAL_SLEEP (Core+Deep+REM)
//  Payload keys: SOURCE, SOURCE_BUNDLE, TIMEZONE, TOTAL_SLEEP, SLEEP_IN_BED,
//                SLEEP_LIGHT, SLEEP_DEEP, SLEEP_REM, SLEEP_UNSPECIFIED, SLEEP_AWAKE,
//                BED_TIME, WAKE_TIME, START_DATE, END_DATE
//

import Flutter
import HealthKit
import Foundation

// MARK: - SleepDataManager

@available(iOS 14.0, *)
public class SleepDataManager: NSObject, AppLifecycleObserver {
    static let shared = SleepDataManager()
    
    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    // Live streaming (foreground)
    private var anchor: HKQueryAnchor?
    private var liveUpdateTask: Task<Void, Never>?
    private var isLiveStreaming = false

    // Background monitoring
    private var observerQuery: HKObserverQuery?
    private var isBackgroundMonitoring = false

    // Configuration
    private var monitorStartDate: Date?

    // Deduplication: track the last delivered (sessionId, wakeTime) pair so the same
    // payload is not re-posted to the API on every HealthKit observer fire.
    // Re-delivery only happens when WAKE_TIME advances (new sleep data written by Apple Watch).
    private var lastDeliveredSessionId: String?
    private var lastDeliveredWakeTime: String?
    
    // MARK: - Initialization
    
    private override init() {
        super.init()
        AppLifecycleManager.shared.addObserver(self)
        debugPrint("🛏️ [SleepDataManager] initialized")
    }

    deinit {
        AppLifecycleManager.shared.removeObserver(self)
    }
    
    // MARK: - Auto-Start on App Launch
    
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            debugPrint("🛍️ [SleepDataManager] autoStart skipped — user not logged in")
            // Remote-log so Cloud Logs show WHY monitoring never starts on background relaunch.
            SleepRemoteLogger.log(.warn, step: "autoStart", message: "skipped — user not logged in", context: ["class": "SleepDataManager", "method": "autoStartIfConfigured"])
            return
        }
        guard HumangoHealthPlugin.delegate != nil else {
            debugPrint("🛍️ [SleepDataManager] autoStart skipped — no delegate configured")
            // Remote-log: delegate nil means onSleepSessionReady will never be called even if
            // the observer fires. This is the most common silent failure on cold background launch.
            SleepRemoteLogger.log(.warn, step: "autoStart", message: "skipped — delegate nil (set HumangoHealthPlugin.delegate before calling startAllBackgroundMonitoring)", context: ["class": "SleepDataManager", "method": "autoStartIfConfigured"])
            return
        }
        guard monitorStartDate == nil else {
            debugPrint("🛏️ [SleepDataManager] autoStart skipped — monitoring already active")
            SleepRemoteLogger.log(.info, step: "autoStart", message: "skipped — already active", context: ["class": "SleepDataManager", "method": "autoStartIfConfigured"])
            return
        }

        let startDate = Date().addingTimeInterval(-12 * 60 * 60)
        monitorStartDate = startDate

        let mode = AppLifecycleManager.shared.isInForeground ? "foreground" : "background"
        SleepRemoteLogger.log(.info, step: "autoStart", message: "starting", context: [
            "class":     "SleepDataManager",
            "method":    "autoStartIfConfigured",
            "mode":      mode,
            "startDate": isoFormatter.string(from: startDate),
        ])

        if AppLifecycleManager.shared.isInForeground {
            startLiveUpdates()
        } else {
            startBackgroundMonitoring()
        }

        debugPrint("🛏️ [SleepDataManager] ✅ auto-started (\(mode)) from \(isoFormatter.string(from: startDate))")
    }

    /// Stops all active monitoring and clears all persisted sleep data and configuration.
    /// Called on user logout to ensure no background activity continues and data is wiped.
    func stopAndClearAll() {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil
        lastDeliveredSessionId = nil
        lastDeliveredWakeTime  = nil
        debugPrint("🛍️ [SleepDataManager] ✅ stopped all monitoring (logout)")
    }
    
    // MARK: - AppLifecycleObserver (Native iOS lifecycle)
    
    func appDidEnterForeground() {
        switchToForegroundMode()
    }
    
    func appDidEnterBackground() {
        switchToBackgroundMode()
    }
    
    // MARK: - Mode Switching (shared logic)
    
    private func switchToForegroundMode() {
        guard monitorStartDate != nil else { return }
        stopBackgroundMonitoring()
        startLiveUpdates()
        debugPrint("🛍️ [SleepDataManager] → foreground mode")
    }

    private func switchToBackgroundMode() {
        guard monitorStartDate != nil else { return }
        stopLiveUpdates()
        startBackgroundMonitoring()
        debugPrint("🛍️ [SleepDataManager] → background mode")
    }
    
    // MARK: - Method Channel Handler
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method
        let requiresLogin = [
            "getSleepData", "startSleepMonitoring", "calculateSleepPayload",
        ].contains(method)
        if requiresLogin {
            guard UserAuthStateManager.shared.guardLoggedInForHealthData(result: result) else { return }
        }
        switch method {
        case "getSleepData":
            handleGetSleepData(call, result: result)
            
        case "startSleepMonitoring":
            handleStartMonitoring(call, result: result)
            
        case "stopSleepMonitoring":
            handleStopMonitoring(result: result)

        case "calculateSleepPayload":
            handleCalculateSleepPayload(call, result: result)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Method Handlers
    
    private func handleGetSleepData(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        var startDate: Date?
        var endDate: Date?
        
        if let args = call.arguments as? [String: Any] {
            if let startStr = args["startDate"] as? String {
                startDate = DateUtils.parseDate(from: startStr)
            }
            if let endStr = args["endDate"] as? String {
                endDate = DateUtils.parseDate(from: endStr)
            }
        }
        
        Task {
            do {
                let sleepData = try await fetchSleepData(startDate: startDate, endDate: endDate)
                DispatchQueue.main.async {
                    result(sleepData)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "SLEEP_FETCH_ERROR",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }
    
    private func handleStartMonitoring(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        // Parse start date from arguments (defaults to 24 hours ago)
        var startDate = Date().addingTimeInterval(-24 * 60 * 60)
        
        if let args = call.arguments as? [String: Any],
           let startStr = args["startDate"] as? String {
            if let parsed = DateUtils.parseDate(from: startStr) {
                startDate = parsed
            }
        }
        
        monitorStartDate = startDate
        
        // Both API and localStorage modes use the same foreground/background strategy:
        // Foreground → HKAnchoredObjectQueryDescriptor (live streaming)
        // Background → HKObserverQuery
        // The delivery mode (API vs EventChannel) is handled inside each path.
        if AppLifecycleManager.shared.isInForeground {
            startLiveUpdates()
        } else {
            startBackgroundMonitoring()
        }
        
        debugPrint("🛍️ [SleepDataManager] started monitoring from \(isoFormatter.string(from: startDate))")
        result(["status": "started", "startDate": isoFormatter.string(from: startDate)])
    }

    private func handleStopMonitoring(result: @escaping FlutterResult) {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil
        debugPrint("🛏️ [SleepDataManager] stopped monitoring")
        result(["status": "stopped"])
    }
    
    /// Exposes `calculateSleepPayload(from:)` over the Flutter method channel.
    /// Accepts optional `startDate`/`endDate` ISO8601 strings; defaults to the
    /// current 6 PM window when omitted.
    private func handleCalculateSleepPayload(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        var startDate: Date?
        var endDate: Date?

        if let args = call.arguments as? [String: Any] {
            if let startStr = args["startDate"] as? String {
                startDate = DateUtils.parseDate(from: startStr)
            }
            if let endStr = args["endDate"] as? String {
                endDate = DateUtils.parseDate(from: endStr)
            }
        }

        let (queryStart, queryEnd): (Date, Date)
        if let s = startDate, let e = endDate {
            (queryStart, queryEnd) = (s, e)
        } else {
            (queryStart, queryEnd) = sixPMWindow()
        }

        Task {
            do {
                let samples = try await fetchSleepSamples(from: queryStart, to: queryEnd)
                if let payload = calculateSleepPayload(from: samples) {
                    DispatchQueue.main.async { result(payload) }
                } else {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "NO_VALID_SLEEP",
                            message: "No valid sleep groups found (all groups < 3h span)",
                            details: nil
                        ))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "FETCH_ERROR",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }
    
    // MARK: - Fetch Sleep Data
    
    /// Fetches sleep data for the specified time range
    /// - Parameters:
    ///   - startDate: Start of the time range (defaults to 24 hours ago)
    ///   - endDate: End of the time range (defaults to now)
    private func fetchSleepData(startDate: Date? = nil, endDate: Date? = nil) async throws -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "SleepData", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HealthKit is not available on this device"
            ])
        }
        
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw NSError(domain: "SleepData", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Sleep analysis type is not available"
            ])
        }
        
        // Note: We cannot check read authorization status - Apple's privacy model
        // returns .notDetermined even if user granted/denied read access.
        // We simply query the data and return empty results if access is denied.
        
        // Define time range: use provided dates or default to last 24 hours
        let queryEndDate = endDate ?? Date()
        let queryStartDate = startDate ?? Calendar.current.date(byAdding: .hour, value: -24, to: queryEndDate)!
        
        // Use [] (overlap) so any sample that overlaps the window is included.
        // .strictStartDate would exclude sessions that started before the window
        // (e.g. sleep beginning before midnight when querying from midnight).
        let predicate = HKQuery.predicateForSamples(
            withStart: queryStartDate,
            end: queryEndDate,
            options: []
        )
        
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )
        
        // Execute query
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let categorySamples = results as? [HKCategorySample] ?? []
                continuation.resume(returning: categorySamples)
            }
            
            healthStore.execute(query)
        }
        
        // Convert samples to JSON
        var sleepSamples: [[String: Any]] = []
        var totalSleepSeconds: Double = 0
        var stageTotals: [String: Double] = [
            "inBed": 0,
            "asleepUnspecified": 0,
            "awake": 0,
            "asleepCore": 0,
            "asleepDeep": 0,
            "asleepREM": 0
        ]
        
        for sample in samples {
            let sampleDict = convertSampleToDict(sample)
            sleepSamples.append(sampleDict)

            // Keep raw duration as provided by HealthKit with no library-side rounding.
            let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
            let stageName = sleepStageString(from: sample.value)
            
            // Accumulate totals (exclude "inBed" and "awake" from total sleep)
            stageTotals[stageName, default: 0] += durationSeconds
            
            if stageName != "inBed" && stageName != "awake" {
                totalSleepSeconds += durationSeconds
            }
        }
        
        debugPrint("🛏️ [SleepDataManager] fetched \(samples.count) samples from \(isoFormatter.string(from: queryStartDate)) to \(isoFormatter.string(from: queryEndDate))")
        
        return [
            "samples": sleepSamples,
            "sampleCount": samples.count,
            "totalSleepSeconds": totalSleepSeconds,
            "totalSleepMinutes": totalSleepSeconds / 60.0,
            "totalSleepHours": totalSleepSeconds / 3600.0,
            "stageTotals": stageTotals.mapValues { ["seconds": $0, "minutes": $0 / 60.0] },
            "fetchedFrom": isoFormatter.string(from: queryStartDate),
            "fetchedTo": isoFormatter.string(from: queryEndDate)
        ]
    }
    
    // MARK: - Foreground Monitoring (HKAnchoredObjectQueryDescriptor)
    
    /// Foreground monitoring via HKAnchoredObjectQueryDescriptor (iOS 15+).
    /// On each new batch of samples, fetches the full 6PM window and stores to local cache.
    /// Delivery to backend only happens via the background observer path.
    private func startLiveUpdates() {
        guard !isLiveStreaming else { return }
        guard let startDate = monitorStartDate else { return }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            debugPrint("🛏️ [SleepDataManager] sleep analysis type not available")
            return
        }

        isLiveStreaming = true
        let livePredicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: [.strictStartDate])

        if #available(iOS 15.0, *) {
            let descriptor = HKAnchoredObjectQueryDescriptor(
                predicates: [.categorySample(type: sleepType, predicate: livePredicate)],
                anchor: anchor
            )
            let stream = descriptor.results(for: healthStore)

            liveUpdateTask?.cancel()
            liveUpdateTask = Task { [weak self] in
                guard let self = self else { return }
                do {
                    for try await update in stream {
                        self.anchor = update.newAnchor
                        if !update.addedSamples.isEmpty {
                            debugPrint("🛍️ [SleepDataManager] foreground: \(update.addedSamples.count) new samples")
                        }
                        for deleted in update.deletedObjects {
                            debugPrint("🛏️ [SleepDataManager] foreground: sample deleted \(deleted.uuid.uuidString)")
                        }
                    }
                } catch {
                    debugPrint("🛏️ [SleepDataManager] foreground monitoring error: \(error)")
                }
            }
            debugPrint("🛍️ [SleepDataManager] started foreground monitoring")
        } else {
            debugPrint("🛏️ [SleepDataManager] foreground monitoring requires iOS 15.0+")
        }
    }

    private func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        isLiveStreaming = false
        debugPrint("🛏️ [SleepDataManager] stopped foreground monitoring")
    }
    
    // MARK: - Background Monitoring

    /// Starts background monitoring using HKObserverQuery.
    /// On every fire: compute 6PM window → fetch samples → calculateSleepPayload → delegate.onSleepSessionReady.
    private func startBackgroundMonitoring() {
        guard !isBackgroundMonitoring else { return }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            debugPrint("🛏️ [SleepDataManager] sleep analysis type not available")
            return
        }

        isBackgroundMonitoring = true
        SleepRemoteLogger.log(.info, step: "startBackgroundMonitoring", message: "registering observer query", context: ["class": "SleepDataManager", "method": "startBackgroundMonitoring"])

        Task {
            do {
                try await healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate)
                debugPrint("🛏️ [SleepDataManager] background delivery enabled")
                SleepRemoteLogger.log(.info, step: "startBackgroundMonitoring", message: "background delivery enabled", context: ["class": "SleepDataManager", "method": "startBackgroundMonitoring"])
            } catch {
                debugPrint("🛏️ [SleepDataManager] enableBackgroundDelivery failed: \(error)")
                SleepRemoteLogger.log(.error, step: "startBackgroundMonitoring", message: "enableBackgroundDelivery failed", context: ["class": "SleepDataManager", "method": "startBackgroundMonitoring", "error": "\(error)"])
            }
        }

        observerQuery = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            // NOTE: Do NOT use `defer { completion() }` here.
            // completion() must be called AFTER the async delivery work finishes so iOS
            // does not suspend the app before fetchSleepSamples / deliverPayload / the
            // remote log network request complete.

            let fireTime = self.isoFormatter.string(from: Date())

            if let error = error {
                debugPrint("🛏️ [SleepDataManager] observer error at \(fireTime): \(error)")
                SleepRemoteLogger.log(.error, step: "observer", message: "observer error", context: ["class": "SleepDataManager", "method": "startBackgroundMonitoring", "error": "\(error)"])
                completion()
                return
            }

            guard UserAuthStateManager.shared.isLoggedIn else {
                debugPrint("🛏️ [SleepDataManager] observer fired at \(fireTime) — skipped (user not logged in)")
                SleepRemoteLogger.log(.warn, step: "observer", message: "skipped — user not logged in", context: ["class": "SleepDataManager", "method": "startBackgroundMonitoring"])
                completion()
                return
            }

            debugPrint("🛏️ [SleepDataManager] observer fired at \(fireTime) — processing (userId=\(UserAuthStateManager.shared.userId ?? "?"))")
            SleepRemoteLogger.log(.info, step: "observer_fired", message: "processing", context: ["class": "SleepDataManager", "method": "startBackgroundMonitoring", "fireTime": fireTime])
            Task {
                await self.handleBackgroundObserverFired()
                // Signal HealthKit AFTER all async work is complete so iOS keeps
                // the app alive for the full fetch → compute → deliver pipeline.
                completion()
            }
        }

        if let query = observerQuery {
            healthStore.execute(query)
            debugPrint("🛏️ [SleepDataManager] started background monitoring")
        }
    }

    private func stopBackgroundMonitoring() {
        if let query = observerQuery {
            healthStore.stop(query)
            observerQuery = nil
        }
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            healthStore.disableBackgroundDelivery(for: sleepType) { _, _ in }
        }
        isBackgroundMonitoring = false
        debugPrint("🛏️ [SleepDataManager] stopped background monitoring")
    }

    // MARK: - Background Observer Logic

    private func handleBackgroundObserverFired() async {
        let (queryStart, queryEnd) = sixPMWindow()

        SleepRemoteLogger.log(.info, step: "fetch", message: "fetching 6PM window", context: [
            "class":       "SleepDataManager",
            "method":      "handleBackgroundObserverFired",
            "windowStart": isoFormatter.string(from: queryStart),
            "windowEnd":   isoFormatter.string(from: queryEnd),
        ])

        let rawSamples: [HKCategorySample]
        do {
            rawSamples = try await fetchSleepSamples(from: queryStart, to: queryEnd)
        } catch {
            debugPrint("🛏️ [SleepDataManager] background fetch failed: \(error)")
            SleepRemoteLogger.log(.error, step: "fetch", message: "HealthKit fetch failed", context: ["class": "SleepDataManager", "method": "handleBackgroundObserverFired", "error": "\(error)"])
            return
        }

        guard !rawSamples.isEmpty else {
            SleepRemoteLogger.log(.info, step: "fetch", message: "no samples in window", context: ["class": "SleepDataManager", "method": "handleBackgroundObserverFired"])
            return
        }

        SleepRemoteLogger.log(.info, step: "fetch", message: "fetched \(rawSamples.count) samples", context: ["class": "SleepDataManager", "method": "handleBackgroundObserverFired"])
        await deliverPayload(samples: rawSamples, queryStart: queryStart, queryEnd: queryEnd)
    }

    // MARK: - Payload Delivery

    func deliverPayload(samples: [HKCategorySample], queryStart: Date, queryEnd: Date) async {
        guard let payload = calculateSleepPayload(from: samples) else {
            SleepRemoteLogger.log(.info, step: "payload", message: "calculateSleepPayload returned nil (no valid groups)", context: ["class": "SleepDataManager", "method": "deliverPayload"])
            return
        }

        let totalSec  = payload["TOTAL_SLEEP"] as? Double ?? 0
        let source    = payload["SOURCE"] as? String ?? ""
        SleepRemoteLogger.log(.info, step: "payload", message: "built", context: [
            "class":     "SleepDataManager",
            "method":    "deliverPayload",
            "source":    source,
            "totalSec":  "\(totalSec)",
            "bedTime":   payload["BED_TIME"]  as? String ?? "",
            "wakeTime":  payload["WAKE_TIME"] as? String ?? "",
        ])

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            debugPrint("🛏️ [SleepDataManager] deliverPayload: serialization failed")
            SleepRemoteLogger.log(.error, step: "deliver", message: "JSON serialization failed", context: ["class": "SleepDataManager", "method": "deliverPayload"])
            return
        }

        let sessionId = payload["BED_TIME"] as? String ?? isoFormatter.string(from: queryStart)
        let wakeTime  = payload["WAKE_TIME"] as? String ?? ""

        // Deduplicate: skip delivery if this exact (sessionId, wakeTime) was already sent.
        // Re-deliver when wakeTime advances so incremental Watch updates propagate to the API.
        if sessionId == lastDeliveredSessionId && wakeTime == lastDeliveredWakeTime {
            SleepRemoteLogger.log(.info, step: "deliver", message: "skipped — identical session already delivered", context: [
                "class":     "SleepDataManager",
                "method":    "deliverPayload",
                "sessionId": sessionId,
                "wakeTime":  wakeTime,
            ])
            return
        }

        if let delegate = HumangoHealthPlugin.delegate {
            lastDeliveredSessionId = sessionId
            lastDeliveredWakeTime  = wakeTime
            // `await` so the host app's upload completes before we return.
            // completion() is called after this function returns, so iOS keeps
            // the app alive for the full fetch → compute → upload pipeline.
            await delegate.onSleepSessionReady(json: jsonString, sessionId: sessionId)
            SleepRemoteLogger.log(.info, step: "deliver", message: "onSleepSessionReady delivered", context: [
                "class":     "SleepDataManager",
                "method":    "deliverPayload",
                "sessionId": sessionId,
                "wakeTime":  wakeTime,
                "jsonBytes":  jsonData.count,
                "payload":   payload,
            ])
        } else {
            debugPrint("⚠️ [SleepDataManager] delegate is nil — sleep session \(sessionId) not delivered")
            SleepRemoteLogger.log(.warn, step: "deliver", message: "delegate is nil — not delivered", context: ["class": "SleepDataManager", "method": "deliverPayload", "sessionId": sessionId])
        }
    }

    // MARK: - 6PM Query Window

    /// Returns the query window: 6:00 PM yesterday → now.
    /// Computes the HealthKit query window based on the time the observer fires:
    ///
    ///  • Before noon  (00:00 – 11:59) : start = yesterday 18:00  → overnight sleep window
    ///  • Noon – 18:00 (12:00 – 17:59) : start = yesterday 18:00  → late-delivery of last night's sleep
    ///  • After 18:00  (18:00 – 23:59) : start = today     18:00  → new sleep session starting tonight
    ///
    /// In all cases end = now.
    private func sixPMWindow() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let today = cal.startOfDay(for: now)

        let windowStart: Date
        if hour >= 18 {
            // After 6 PM today — new overnight window starts now
            windowStart = cal.date(byAdding: .hour, value: 18, to: today)!
        } else {
            // Before 6 PM (includes both overnight/morning and noon–6 PM transitions)
            // → look back to yesterday 6 PM to capture last night's sleep
            let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
            windowStart = cal.date(byAdding: .hour, value: 18, to: yesterday)!
        }

        debugPrint("🛏️ [SleepDataManager] sixPMWindow: hour=\(hour) → [\(isoFormatter.string(from: windowStart)), now]")
        return (windowStart, now)
    }

    // MARK: - Raw Sample Fetch (async, throws)

    private func fetchSleepSamples(from start: Date, to end: Date) async throws -> [HKCategorySample] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw NSError(domain: "SleepData", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sleep analysis type unavailable"])
        }
        // Use [] (overlap) — same rationale as fetchSleepData: sleep sessions can
        // start before or end after the query boundary.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error = error { cont.resume(throwing: error); return }
                let samples = results as? [HKCategorySample] ?? []
                debugPrint("🛏️ [SleepDataManager] fetchSleepSamples: \(samples.count) samples from \(self.isoFormatter.string(from: start)) to \(self.isoFormatter.string(from: end))")
                cont.resume(returning: samples)
            }
            healthStore.execute(q)
        }
    }

    // MARK: - Flat Aggregated Payload Builder

    /// Builds the flat aggregated payload in the format used by the backend.
    ///
    /// Groups samples by source name. Picks source with highest TOTAL_SLEEP (Core+Deep+REM).
    /// Matches the SleepResult.toDict() shape from the legacy humango-mobile app,
    /// with the addition of SOURCE_BUNDLE, TIMEZONE, BED_TIME and WAKE_TIME.
    private func buildAggregatedPayload(samples: [HKCategorySample], queryStart: Date, queryEnd: Date) -> [String: Any]? {
        // --- Group by source name ---
        var bySource: [String: [HKCategorySample]] = [:]
        for s in samples {
            let name = s.sourceRevision.source.name
            bySource[name, default: []].append(s)
        }

        // --- Accumulate per source ---
        struct SourceStats {
            var bundle = ""
            var timezone: String?
            var inBed: Double = 0
            var unspecified: Double = 0
            var awake: Double = 0
            var core: Double = 0
            var deep: Double = 0
            var rem: Double = 0
            var minStart: Date?
            var maxEnd: Date?
        }

        var stats: [String: SourceStats] = [:]

        for (name, list) in bySource {
            var s = SourceStats()
            s.bundle = list.first?.sourceRevision.source.bundleIdentifier ?? ""
            // Timezone from HKMetadataKeyTimeZone on any sample
            s.timezone = list.compactMap { ($0.metadata?[HKMetadataKeyTimeZone] as? String) }.first

            for sample in list {
                // Use raw segment duration in seconds from HealthKit with no
                // library-side rounding/truncation so downstream can decide display policy.
                let dur = sample.endDate.timeIntervalSince(sample.startDate)
                switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                case .inBed:             s.inBed        += dur
                case .asleepUnspecified: s.unspecified  += dur
                case .awake:             s.awake        += dur
                case .asleepCore:        s.core         += dur
                case .asleepDeep:        s.deep         += dur
                case .asleepREM:         s.rem          += dur
                default:                 break
                }
                if s.minStart == nil || sample.startDate < s.minStart! { s.minStart = sample.startDate }
                if s.maxEnd   == nil || sample.endDate   > s.maxEnd!   { s.maxEnd   = sample.endDate   }
            }
            stats[name] = s
        }

        // --- Pick winner (highest TOTAL_SLEEP = Core+Deep+REM) ---
        guard let (winnerName, winner) = stats.max(by: { ($0.value.core + $0.value.deep + $0.value.rem) < ($1.value.core + $1.value.deep + $1.value.rem) }) else {
            return nil
        }

        let totalSleep = winner.core + winner.deep + winner.rem
        guard totalSleep > 0 else { return nil }

        if stats.count > 1 {
            debugPrint("🛏️ [SleepDataManager] \(stats.count) sources — winner: \(winnerName) (\(totalSleep)s). Dropped: \(stats.keys.filter { $0 != winnerName }.joined(separator: ", "))")
        }

        return [
            "SOURCE":            winnerName,
            "SOURCE_BUNDLE":     winner.bundle,
            "TIMEZONE":          winner.timezone ?? TimeZone.current.identifier,
            "TOTAL_SLEEP":       totalSleep,
            "SLEEP_IN_BED":      winner.inBed,
            "SLEEP_LIGHT":       winner.core,
            "SLEEP_DEEP":        winner.deep,
            "SLEEP_REM":         winner.rem,
            "SLEEP_UNSPECIFIED": winner.unspecified,
            "SLEEP_AWAKE":       winner.awake,
            "BED_TIME":          winner.minStart.map { isoFormatter.string(from: $0) } as Any,
            "WAKE_TIME":         winner.maxEnd.map   { isoFormatter.string(from: $0) } as Any,
            "START_DATE":        isoFormatter.string(from: queryStart),
            "END_DATE":          isoFormatter.string(from: queryEnd)
        ]
    }

    // MARK: - Sample-Based Sleep Calculation

    /// Calculates a flat aggregated sleep payload directly from a list of raw HealthKit samples.
    ///
    /// Algorithm:
    ///   Step 1 — Sort all samples by `startDate` ascending.
    ///   Step 2 — Group consecutive samples where the gap between
    ///             `sample[i].startDate` and `sample[i-1].endDate` is ≤ 2 hours.
    ///             Any group whose span (first.startDate → max(endDate)) is < 3 hours
    ///             is discarded as a nap or data artifact. `max(endDate)` is used
    ///             instead of `last.endDate` because sorting is by startDate — the last
    ///             sample by start may not have the latest end (e.g. a long inBed sample).
    ///   Step 3 — Merge all valid groups and delegate to `buildAggregatedPayload` for
    ///             source selection and stage-level duration totals.
    ///
    /// - Parameter samples: Raw `HKCategorySample` array from HealthKit (any order).
    /// - Returns: Aggregated sleep payload, or `nil` if no valid sleep groups are found.
    func calculateSleepPayload(from samples: [HKCategorySample]) -> [String: Any]? {
        guard !samples.isEmpty else { return nil }

        // ── Step 1: Sort by startDate ──────────────────────────────────────────
        let sorted = samples.sorted { $0.startDate < $1.startDate }

        // ── Step 2: Group consecutive samples (gap ≤ 2 hours) ─────────────────
        let maxGap: TimeInterval     = 2 * 60 * 60   // 2 hours
        let minGroupSpan: TimeInterval = 3 * 60 * 60 // 3 hours

        var groups: [[HKCategorySample]] = []
        var currentGroup: [HKCategorySample] = [sorted[0]]

        for i in 1 ..< sorted.count {
            let gap = sorted[i].startDate.timeIntervalSince(currentGroup.last!.endDate)
            if gap <= maxGap {
                // Within 2-hour tolerance — belongs to the same session group
                currentGroup.append(sorted[i])
            } else {
                // Gap exceeds 2 hours — flush current group and start a new one
                groups.append(currentGroup)
                currentGroup = [sorted[i]]
            }
        }
        groups.append(currentGroup) // flush final group

        // Discard groups whose total span (first.startDate → maxEndDate) < 3 hours.
        // Use max(endDate) across the group — NOT group.last — because sorting is by
        // startDate, so group.last has the latest start but NOT necessarily the latest end.
        // (e.g. an inBed sample starting early but ending after all stage samples)
        let validGroups = groups.filter { group -> Bool in
            guard let first = group.first else { return false }
            let maxEnd = group.max(by: { $0.endDate < $1.endDate })!.endDate
            return maxEnd.timeIntervalSince(first.startDate) >= minGroupSpan
        }

        guard !validGroups.isEmpty else {
            debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: no valid sleep groups (all < 3h span)")
            return nil
        }

        let totalGroups = groups.count
        let validSamples = validGroups.flatMap { $0 }
        debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: \(validGroups.count)/\(totalGroups) group(s) valid, \(validSamples.count) samples retained")

        // ── Step 3: Merge valid groups → build aggregated payload ──────────────
        // queryStart: earliest startDate (validSamples is sorted by startDate, so .first is correct)
        // queryEnd:   latest endDate across ALL valid samples — again must use max(endDate),
        //             not .last!.endDate, for the same reason as the span filter above.
        let queryStart = validSamples.first!.startDate
        let queryEnd   = validSamples.max(by: { $0.endDate < $1.endDate })!.endDate

        return buildAggregatedPayload(samples: validSamples, queryStart: queryStart, queryEnd: queryEnd)
    }

    // MARK: - Convert Sample to Dictionary
    
    private func convertSampleToDict(_ sample: HKCategorySample) -> [String: Any] {
        let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
        let stageName = sleepStageString(from: sample.value)
        
        var dict: [String: Any] = [
            "uuid": sample.uuid.uuidString,
            "startDate": isoFormatter.string(from: sample.startDate),
            "endDate": isoFormatter.string(from: sample.endDate),
            "value": sample.value,
            "sleepStage": stageName,
            "durationSeconds": durationSeconds,
            "durationMinutes": durationSeconds / 60.0
        ]
        
        // Source information
        dict["sourceName"] = sample.sourceRevision.source.name
        dict["sourceBundle"] = sample.sourceRevision.source.bundleIdentifier
        
        // Device information (if available)
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
        
        // Metadata (if available)
        if let metadata = sample.metadata, !metadata.isEmpty {
            var metadataDict: [String: Any] = [:]
            for (key, value) in metadata {
                // Convert metadata values to JSON-safe types
                if let stringValue = value as? String {
                    metadataDict[key] = stringValue
                } else if let numberValue = value as? NSNumber {
                    metadataDict[key] = numberValue
                } else if let dateValue = value as? Date {
                    metadataDict[key] = isoFormatter.string(from: dateValue)
                } else {
                    metadataDict[key] = String(describing: value)
                }
            }
            dict["metadata"] = metadataDict
        }
        
        // Include raw JSON representation
        dict["rawJson"] = dict
        
        return dict
    }
    
    // MARK: - Sleep Stage Conversion
    
    private func sleepStageString(from value: Int) -> String {
        guard let sleepValue = HKCategoryValueSleepAnalysis(rawValue: value) else {
            return "unknown"
        }
        
        switch sleepValue {
        case .inBed:
            return "inBed"
        case .asleepUnspecified:
            return "asleepUnspecified"
        case .awake:
            return "awake"
        case .asleepCore:
            return "asleepCore"
        case .asleepDeep:
            return "asleepDeep"
        case .asleepREM:
            return "asleepREM"
        @unknown default:
            return "unknown"
        }
    }
}
