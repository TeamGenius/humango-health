//
//  SleepDataManager.swift
//  humango_health
//
//  Fetches and monitors sleep data from Apple HealthKit.
//
//  Background flow (new):
//  HKObserverQuery fires
//  └─ guard: user must be logged in
//  └─ isUserCurrentlyInBed()?
//       YES → fetch 6PM-yesterday→now → store local cache (user still sleeping)
//       NO  → fetch 6PM-yesterday→now → build flat aggregated payload → POST to API
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

// MARK: - UserDefaults Keys for Sleep Data

private struct SleepDataKeys {
    static let storedSleepData = "com.humango.health.storedSleepData"
    static let lastFetchDate = "com.humango.health.lastSleepFetchDate"
    static let sleepSessionConfig = "com.humango.health.sleepSessionConfig"
}

// MARK: - SleepDataManager

@available(iOS 14.0, *)
public class SleepDataManager: NSObject, AppLifecycleObserver {
    static let shared = SleepDataManager()
    
    private let healthStore = HKHealthStore()
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
    // 15-min re-check timer: started when user is confirmed in bed on observer fire.
    // When it fires, inBed is re-checked — if user woke up the payload is delivered;
    // if still in bed the timer is not restarted and the next HK observer handles it.
    private var inBedCheckTimer: Timer?

    private let deliveryManager = SleepBackgroundDeliveryManager.shared

    // Configuration
    private var monitorStartDate: Date?
    
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
    
    /// Auto-starts sleep monitoring if `configureSleepBackgroundDelivery` has armed delivery.
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            debugPrint("🛏️ [SleepDataManager] autoStart skipped — user not logged in")
            return
        }
        guard deliveryManager.isArmedForAutoStart else {
            debugPrint("🛏️ [SleepDataManager] autoStart skipped — sleep delivery not armed")
            return
        }
        guard monitorStartDate == nil else {
            debugPrint("🛏️ [SleepDataManager] autoStart skipped — monitoring already active")
            return
        }

        let startDate = Date().addingTimeInterval(-12 * 60 * 60)
        monitorStartDate = startDate

        if AppLifecycleManager.shared.isInForeground {
            startLiveUpdates()
        } else {
            startBackgroundMonitoring()
        }

        debugPrint("🛏️ [SleepDataManager] ✅ auto-started from \(isoFormatter.string(from: startDate))")
    }

    /// Stops all active monitoring and clears all persisted sleep data and configuration.
    /// Called on user logout to ensure no background activity continues and data is wiped.
    func stopAndClearAll() {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil
        clearStoredSleepData()
        deliveryManager.clearConfiguration()
        debugPrint("🛏️ [SleepDataManager] ✅ stopped all monitoring and cleared data (logout)")
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
        debugPrint("🛏️ [SleepDataManager] → foreground mode (delivery=\(SleepBackgroundDeliveryManager.deliveryModeLogLabel))")
    }

    private func switchToBackgroundMode() {
        guard monitorStartDate != nil else { return }
        stopLiveUpdates()
        startBackgroundMonitoring()
        debugPrint("🛏️ [SleepDataManager] → background mode (delivery=\(SleepBackgroundDeliveryManager.deliveryModeLogLabel))")
    }
    
    // MARK: - Method Channel Handler
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getSleepData":
            handleGetSleepData(call, result: result)
            
        case "startSleepMonitoring":
            handleStartMonitoring(call, result: result)
            
        case "stopSleepMonitoring":
            handleStopMonitoring(result: result)
            
        case "fetchStoredSleepData":
            handleFetchStoredSleepData(result: result)
            
        case "clearStoredSleepData":
            handleClearStoredSleepData(result: result)
            
        case "configureSleepBackgroundDelivery":
            handleConfigureSleepBackgroundDelivery(call, result: result)
            
        case "getLocalSleepSessions":
            handleGetLocalSleepSessions(result: result)
            
        case "enterForeground":
            // Keep for backward compatibility, but native lifecycle is preferred
            switchToForegroundMode()
            result(nil)
            
        case "enterBackground":
            // Keep for backward compatibility, but native lifecycle is preferred
            switchToBackgroundMode()
            result(nil)
            
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
                startDate = ISO8601DateFormatter().date(from: startStr) ?? isoFormatter.date(from: startStr)
            }
            if let endStr = args["endDate"] as? String {
                endDate = ISO8601DateFormatter().date(from: endStr) ?? isoFormatter.date(from: endStr)
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
            if let parsed = ISO8601DateFormatter().date(from: startStr) ?? isoFormatter.date(from: startStr) {
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
        
        debugPrint("🛏️ [SleepDataManager] started monitoring (delivery=\(SleepBackgroundDeliveryManager.deliveryModeLogLabel)) from \(isoFormatter.string(from: startDate))")
        result(["status": "started", "startDate": isoFormatter.string(from: startDate), "deliveryMode": SleepBackgroundDeliveryManager.deliveryModeLogLabel])
    }

    private func handleStopMonitoring(result: @escaping FlutterResult) {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil
        debugPrint("🛏️ [SleepDataManager] stopped monitoring")
        result(["status": "stopped"])
    }
    
    private func handleFetchStoredSleepData(result: @escaping FlutterResult) {
        let storedData = fetchStoredSleepDataFromUserDefaults()
        result(storedData)
    }

    private func handleClearStoredSleepData(result: @escaping FlutterResult) {
        clearStoredSleepData()
        result(["status": "cleared"])
    }

    private func handleConfigureSleepBackgroundDelivery(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let modeStr = args["mode"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing 'mode' argument", details: nil))
            return
        }

        guard modeStr == "localStorage" else {
            result(FlutterError(code: "INVALID_MODE", message: "Unknown mode \"\(modeStr)\". Use localStorage.", details: nil))
            return
        }

        deliveryManager.arm()

        if monitorStartDate == nil {
            autoStartIfConfigured()
        } else if isLiveStreaming {
            stopLiveUpdates()
            startLiveUpdates()
        }

        debugPrint("🛏️ [SleepDataManager] sleep delivery armed (localStorage)")
        result([
            "status": "configured",
            "mode": SleepBackgroundDeliveryManager.deliveryModeLogLabel,
        ])
    }
    
    private func handleGetLocalSleepSessions(result: @escaping FlutterResult) {
        let sessions = deliveryManager.retrieveLocalSleepSessions()
        result(sessions)
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
        
        let predicate = HKQuery.predicateForSamples(
            withStart: queryStartDate,
            end: queryEndDate,
            options: .strictStartDate
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
                            debugPrint("🛏️ [SleepDataManager] foreground: \(update.addedSamples.count) new samples — refreshing cache")
                            Task {
                                let (queryStart, queryEnd) = self.sixPMWindow()
                                if let rawData = try? await self.fetchSleepData(startDate: queryStart, endDate: queryEnd) {
                                    self.storeSleepDataToUserDefaults(rawData)
                                }
                            }
                        }
                        for deleted in update.deletedObjects {
                            debugPrint("🛏️ [SleepDataManager] foreground: sample deleted \(deleted.uuid.uuidString)")
                        }
                    }
                } catch {
                    debugPrint("🛏️ [SleepDataManager] foreground monitoring error: \(error)")
                }
            }
            debugPrint("🛏️ [SleepDataManager] started foreground monitoring (delivery=\(SleepBackgroundDeliveryManager.deliveryModeLogLabel))")
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
    ///
    /// Flow when observer fires:
    /// 1. Guard: user must be logged in
    /// 2. isUserCurrentlyInBed()?
    ///    YES → fetch 6PM window → store local cache (still sleeping, do not POST)
    ///    NO  → fetch 6PM window → build flat aggregated payload → POST to API (or cache in localStorage mode)
    private func startBackgroundMonitoring() {
        guard !isBackgroundMonitoring else { return }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            debugPrint("🛏️ [SleepDataManager] sleep analysis type not available")
            return
        }

        isBackgroundMonitoring = true

        Task {
            do {
                try await healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate)
                debugPrint("🛏️ [SleepDataManager] background delivery enabled")
            } catch {
                debugPrint("🛏️ [SleepDataManager] enableBackgroundDelivery failed: \(error)")
            }
        }

        observerQuery = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            defer { completion() }

            let fireTime = self.isoFormatter.string(from: Date())

            if let error = error {
                debugPrint("🛏️ [SleepDataManager] observer error at \(fireTime): \(error)")
                Task {
                    await SleepRemoteLogger.shared.log(
                        level: .error,
                        message: "HKObserverQuery error",
                        context: [
                            "step": "observer_fired",
                            "error": error.localizedDescription,
                            "fireTime": fireTime
                        ]
                    )
                }
                return
            }

            guard UserAuthStateManager.shared.isLoggedIn else {
                debugPrint("🛏️ [SleepDataManager] observer fired at \(fireTime) — skipped (user not logged in)")
                Task {
                    await SleepRemoteLogger.shared.log(
                        level: .warn,
                        message: "HKObserver fired but user not logged in — skipped",
                        context: ["step": "observer_auth_guard", "fireTime": fireTime]
                    )
                }
                return
            }

            debugPrint("🛏️ [SleepDataManager] observer fired at \(fireTime) — processing (userId=\(UserAuthStateManager.shared.userId ?? "?"))")
            Task {
                await SleepRemoteLogger.shared.log(
                    level: .info,
                    message: "HKObserverQuery fired — starting background sleep pipeline",
                    context: [
                        "step": "observer_fired",
                        "fireTime": fireTime,
                        "isBackgroundMonitoring": self.isBackgroundMonitoring
                    ]
                )
                await self.handleBackgroundObserverFired()
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
        inBedCheckTimer?.invalidate()
        inBedCheckTimer = nil
        isBackgroundMonitoring = false
        debugPrint("🛏️ [SleepDataManager] stopped background monitoring")
    }

    // MARK: - Background Observer Logic

    /// Core logic executed on every HKObserverQuery fire.
    /// Strictly follows the flow diagram:
    ///  1. isUserCurrentlyInBed? (FIRST — before any HealthKit fetch)
    ///     YES → fetch 6PM window → cache → start 15-min timer → timer re-checks inBed:
    ///           timer-YES (still in bed) → wait for next HK observer (do nothing)
    ///           timer-NO  (woke up)      → fetch fresh data → build payload → POST
    ///     NO  → fetch 6PM window → build aggregated payload → POST
    private func handleBackgroundObserverFired() async {
        let pipelineStartTime = isoFormatter.string(from: Date())

        // ── STEP 1: isUserCurrentlyInBed? — checked FIRST per flow diagram ─────
        let inBedCheckTime = isoFormatter.string(from: Date())
        let currentlyInBed = await isUserCurrentlyInBed()
        let inBedResultTime = isoFormatter.string(from: Date())

        debugPrint("🛏️ [SleepDataManager] [STEP 1] isUserCurrentlyInBed=\(currentlyInBed) (queried=\(inBedCheckTime), result=\(inBedResultTime))")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[STEP 1] isUserCurrentlyInBed check complete",
            context: [
                "step":           "inbed_check",
                "currentlyInBed": currentlyInBed,
                "checkedAt":      inBedCheckTime,
                "resultAt":       inBedResultTime,
                "pipelineStart":  pipelineStartTime
            ]
        )

        // ── STEP 2: Compute 6PM query window ──────────────────────────────────
        let (queryStart, queryEnd) = sixPMWindow()
        let windowStartStr = isoFormatter.string(from: queryStart)
        let windowEndStr   = isoFormatter.string(from: queryEnd)
        debugPrint("🛏️ [SleepDataManager] [STEP 2] 6PM window: \(windowStartStr) → \(windowEndStr)")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[STEP 2] 6PM query window computed",
            context: [
                "step":        "window_computed",
                "windowStart": windowStartStr,
                "windowEnd":   windowEndStr
            ]
        )

        // ── STEP 3: Fetch sleep samples from HealthKit ────────────────────────
        let rawSamples: [HKCategorySample]
        do {
            rawSamples = try await fetchSleepSamples(from: queryStart, to: queryEnd)
        } catch {
            debugPrint("🛏️ [SleepDataManager] [STEP 3] HealthKit fetch failed: \(error)")
            await SleepRemoteLogger.shared.log(
                level: .error,
                message: "[STEP 3] HealthKit fetchSleepSamples threw an error",
                context: [
                    "step":        "hk_fetch_failed",
                    "error":       error.localizedDescription,
                    "windowStart": windowStartStr,
                    "windowEnd":   windowEndStr
                ]
            )
            return
        }

        debugPrint("🛏️ [SleepDataManager] [STEP 3] HealthKit returned \(rawSamples.count) samples")

        // Summarise stage counts and unique sources for logging
        var stageCounts: [String: Int] = [:]
        var sourcesFound: Set<String> = []
        for s in rawSamples {
            let stage = sleepStageString(from: s.value)
            stageCounts[stage, default: 0] += 1
            sourcesFound.insert(s.sourceRevision.source.name)
        }

        await SleepRemoteLogger.shared.log(
            level: rawSamples.isEmpty ? .warn : .info,
            message: rawSamples.isEmpty
                ? "[STEP 3] No sleep samples found in 6PM window"
                : "[STEP 3] HealthKit samples fetched successfully",
            context: [
                "step":        "hk_fetch_complete",
                "sampleCount": rawSamples.count,
                "stageCounts": stageCounts,
                "sources":     Array(sourcesFound).sorted(),
                "windowStart": windowStartStr,
                "windowEnd":   windowEndStr
            ]
        )

        guard !rawSamples.isEmpty else {
            debugPrint("🛏️ [SleepDataManager] [STEP 3] no samples in window — nothing to do")
            return
        }

        // ── STEP 4 (YES branch): User is in bed — cache + start 15-min timer ──
        if currentlyInBed {
            let snapshot = buildRawSnapshot(samples: rawSamples, queryStart: queryStart, queryEnd: queryEnd)
            storeSleepDataToUserDefaults(snapshot)

            debugPrint("🛏️ [SleepDataManager] [STEP 4-YES] user IN BED → cached \(rawSamples.count) samples, starting 15-min re-check timer")
            await SleepRemoteLogger.shared.log(
                level: .info,
                message: "[STEP 4-YES] User in bed — data cached, starting 15-min re-check timer",
                context: [
                    "step":        "cached_inbed_timer_starting",
                    "cachedAt":    isoFormatter.string(from: Date()),
                    "sampleCount": rawSamples.count,
                    "sources":     Array(sourcesFound).sorted(),
                    "stageCounts": stageCounts,
                    "windowStart": windowStartStr,
                    "windowEnd":   windowEndStr
                ]
            )

            startInBedCheckTimer()
            return
        }

        // ── STEP 4 (NO branch): User has woken up — build payload ─────────────
        await deliverPayload(samples: rawSamples,
                             queryStart: queryStart,
                             queryEnd: queryEnd,
                             sourcesFound: sourcesFound,
                             stageCounts: stageCounts,
                             trigger: "observer",
                             pipelineStartTime: pipelineStartTime)
    }

    // MARK: - 15-min In-Bed Re-check Timer

    /// Starts a one-shot 15-minute timer.
    /// When it fires, `isUserCurrentlyInBed` is re-checked:
    ///   - Still in bed → do nothing; wait for the next HKObserver fire
    ///   - Woke up      → fetch fresh 6PM window data → build payload → POST
    private func startInBedCheckTimer() {
        // Cancel any previous timer before starting a new one
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inBedCheckTimer?.invalidate()
            self.inBedCheckTimer = Timer.scheduledTimer(
                withTimeInterval: 15 * 60,
                repeats: false
            ) { [weak self] _ in
                guard let self = self else { return }
                debugPrint("🛏️ [SleepDataManager] [TIMER] 15-min inBed re-check timer fired at \(self.isoFormatter.string(from: Date()))")
                Task { await self.handleInBedTimerFired() }
            }
        }
        debugPrint("🛏️ [SleepDataManager] [TIMER] ⏱ 15-min inBed check timer started at \(isoFormatter.string(from: Date()))")
    }

    /// Called when the 15-min timer fires after the user was confirmed in bed.
    private func handleInBedTimerFired() async {
        let timerFireTime = isoFormatter.string(from: Date())
        debugPrint("🛏️ [SleepDataManager] [TIMER] re-checking inBed after 15-min wait, now=\(timerFireTime)")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[TIMER] 15-min re-check timer fired — querying isUserCurrentlyInBed",
            context: ["step": "timer_fired", "timerFireTime": timerFireTime]
        )

        // Re-check inBed (diagram: second isUserCurrentlyInBed? decision)
        let stillInBed = await isUserCurrentlyInBed()
        let checkResultTime = isoFormatter.string(from: Date())

        debugPrint("🛏️ [SleepDataManager] [TIMER] stillInBed=\(stillInBed) at \(checkResultTime)")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[TIMER] isUserCurrentlyInBed re-check complete",
            context: [
                "step":      "timer_inbed_recheck",
                "stillInBed": stillInBed,
                "checkedAt":  checkResultTime
            ]
        )

        if stillInBed {
            // Diagram: YES → "Wait for next HealthKit Observer Trigger" — do nothing,
            // the next HKObserver fire will restart the whole pipeline.
            debugPrint("🛏️ [SleepDataManager] [TIMER] user STILL in bed → waiting for next HK observer fire (no action)")
            await SleepRemoteLogger.shared.log(
                level: .info,
                message: "[TIMER] User still in bed after 15-min — waiting for next HKObserver trigger",
                context: ["step": "timer_still_inbed", "checkedAt": checkResultTime]
            )
            return
        }

        // Diagram: NO → "Build Aggregated Payload (from cached data) → POST to Backend API"
        debugPrint("🛏️ [SleepDataManager] [TIMER] user NOT in bed → fetching fresh 6PM window data for delivery")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[TIMER] User woke up — fetching fresh 6PM window data to build payload",
            context: ["step": "timer_woke_up", "detectedAt": checkResultTime]
        )

        let (queryStart, queryEnd) = sixPMWindow()
        let windowStartStr = isoFormatter.string(from: queryStart)
        let windowEndStr   = isoFormatter.string(from: queryEnd)

        let rawSamples: [HKCategorySample]
        do {
            rawSamples = try await fetchSleepSamples(from: queryStart, to: queryEnd)
        } catch {
            debugPrint("🛏️ [SleepDataManager] [TIMER] HealthKit fetch failed after timer wake: \(error)")
            await SleepRemoteLogger.shared.log(
                level: .error,
                message: "[TIMER] HealthKit fetch failed after timer-triggered wake",
                context: ["step": "timer_fetch_failed", "error": error.localizedDescription]
            )
            return
        }

        var stageCounts: [String: Int] = [:]
        var sourcesFound: Set<String> = []
        for s in rawSamples {
            let stage = sleepStageString(from: s.value)
            stageCounts[stage, default: 0] += 1
            sourcesFound.insert(s.sourceRevision.source.name)
        }

        debugPrint("🛏️ [SleepDataManager] [TIMER] fetched \(rawSamples.count) samples for timer-triggered delivery")
        await SleepRemoteLogger.shared.log(
            level: rawSamples.isEmpty ? .warn : .info,
            message: rawSamples.isEmpty
                ? "[TIMER] No samples found after timer-triggered wake detection"
                : "[TIMER] Samples fetched — proceeding to build payload",
            context: [
                "step":        "timer_fetch_complete",
                "sampleCount": rawSamples.count,
                "stageCounts": stageCounts,
                "sources":     Array(sourcesFound).sorted(),
                "windowStart": windowStartStr,
                "windowEnd":   windowEndStr
            ]
        )

        guard !rawSamples.isEmpty else { return }

        await deliverPayload(samples: rawSamples,
                             queryStart: queryStart,
                             queryEnd: queryEnd,
                             sourcesFound: sourcesFound,
                             stageCounts: stageCounts,
                             trigger: "timer",
                             pipelineStartTime: timerFireTime)
    }

    // MARK: - Shared Payload Delivery (used by both observer NO path and timer wake path)

    /// Builds the aggregated payload from `samples` and delivers it.
    /// `trigger` is either "observer" (direct wake) or "timer" (15-min re-check wake).
    private func deliverPayload(
        samples: [HKCategorySample],
        queryStart: Date,
        queryEnd: Date,
        sourcesFound: Set<String>,
        stageCounts: [String: Int],
        trigger: String,
        pipelineStartTime: String
    ) async {
        let windowStartStr = isoFormatter.string(from: queryStart)
        let windowEndStr   = isoFormatter.string(from: queryEnd)

        // Build flat aggregated payload
        guard let payload = buildAggregatedPayload(
            samples: samples, queryStart: queryStart, queryEnd: queryEnd
        ) else {
            debugPrint("🛏️ [SleepDataManager] [\(trigger.uppercased())] buildAggregatedPayload=nil (TOTAL_SLEEP=0 for all sources)")
            await SleepRemoteLogger.shared.log(
                level: .warn,
                message: "[\(trigger.uppercased())] Could not build payload — TOTAL_SLEEP is 0 across all sources",
                context: [
                    "step":        "payload_build_failed",
                    "trigger":     trigger,
                    "sampleCount": samples.count,
                    "stageCounts": stageCounts,
                    "sources":     Array(sourcesFound).sorted()
                ]
            )
            return
        }

        let totalMin  = (payload["TOTAL_SLEEP"]       as? Int ?? 0) / 60
        let lightMin  = (payload["SLEEP_LIGHT"]       as? Int ?? 0) / 60
        let deepMin   = (payload["SLEEP_DEEP"]        as? Int ?? 0) / 60
        let remMin    = (payload["SLEEP_REM"]         as? Int ?? 0) / 60
        let awakeMin  = (payload["SLEEP_AWAKE"]       as? Int ?? 0) / 60
        let inBedMin  = (payload["SLEEP_IN_BED"]      as? Int ?? 0) / 60
        let unspecMin = (payload["SLEEP_UNSPECIFIED"] as? Int ?? 0) / 60

        debugPrint("🛏️ [SleepDataManager] [\(trigger.uppercased())] payload built — source=\(payload["SOURCE"] ?? ""), total=\(totalMin)m, L/D/R=\(lightMin)/\(deepMin)/\(remMin)m")
        logPayload(payload)

        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[\(trigger.uppercased())] Aggregated payload built — ready to deliver",
            context: [
                "step":                  "payload_built",
                "trigger":               trigger,
                "SOURCE":                payload["SOURCE"]       as? String ?? "",
                "SOURCE_BUNDLE":         payload["SOURCE_BUNDLE"] as? String ?? "",
                "TIMEZONE":              payload["TIMEZONE"]      as? String ?? "",
                "TOTAL_SLEEP_min":       totalMin,
                "SLEEP_LIGHT_min":       lightMin,
                "SLEEP_DEEP_min":        deepMin,
                "SLEEP_REM_min":         remMin,
                "SLEEP_AWAKE_min":       awakeMin,
                "SLEEP_IN_BED_min":      inBedMin,
                "SLEEP_UNSPECIFIED_min": unspecMin,
                "BED_TIME":              payload["BED_TIME"]   as? String ?? "",
                "WAKE_TIME":             payload["WAKE_TIME"]  as? String ?? "",
                "START_DATE":            payload["START_DATE"] as? String ?? "",
                "END_DATE":              payload["END_DATE"]   as? String ?? "",
                "droppedSources":        Array(sourcesFound.filter { $0 != (payload["SOURCE"] as? String) }).sorted()
            ]
        )

        // Serialise
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            debugPrint("🛏️ [SleepDataManager] [\(trigger.uppercased())] payload serialization failed")
            await SleepRemoteLogger.shared.log(
                level: .error,
                message: "[\(trigger.uppercased())] Payload JSON serialization failed",
                context: ["step": "serialization_failed", "trigger": trigger]
            )
            return
        }

        let sessionId = payload["BED_TIME"] as? String ?? isoFormatter.string(from: queryStart)

        debugPrint("🛏️ [SleepDataManager] [\(trigger.uppercased())] delivering sessionId=\(sessionId) mode=\(SleepBackgroundDeliveryManager.deliveryModeLogLabel) size=\(jsonData.count)B")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[\(trigger.uppercased())] Delivering sleep payload",
            context: [
                "step":         "delivering",
                "trigger":      trigger,
                "sessionId":    sessionId,
                "deliveryMode": SleepBackgroundDeliveryManager.deliveryModeLogLabel,
                "jsonBytes":    jsonData.count
            ]
        )

        await deliveryManager.deliverSleepSession(jsonString, sessionId: sessionId)

        debugPrint("🛏️ [SleepDataManager] [\(trigger.uppercased())] delivery complete for sessionId=\(sessionId)")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[\(trigger.uppercased())] Background sleep pipeline complete",
            context: [
                "step":          "pipeline_complete",
                "trigger":       trigger,
                "sessionId":     sessionId,
                "pipelineStart": pipelineStartTime,
                "pipelineEnd":   isoFormatter.string(from: Date())
            ]
        )
    }

    // MARK: - 6PM Query Window

    /// Returns the query window: 6:00 PM yesterday → now.
    /// Matches the humango-mobile SleepStatisticsManager query window.
    private func sixPMWindow() -> (start: Date, end: Date) {
        var cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        // 6:00 PM yesterday = today's start minus 6 hours
        let windowStart = cal.date(byAdding: .hour, value: -6, to: today)!
        return (windowStart, now)
    }

    // MARK: - Raw Sample Fetch (async, throws)

    private func fetchSleepSamples(from start: Date, to end: Date) async throws -> [HKCategorySample] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw NSError(domain: "SleepData", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sleep analysis type unavailable"])
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: results as? [HKCategorySample] ?? [])
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
            debugPrint("🛏️ [SleepDataManager] \(stats.count) sources — winner: \(winnerName) (\(Int(totalSleep/60))m). Dropped: \(stats.keys.filter { $0 != winnerName }.joined(separator: ", "))")
        }

        return [
            "SOURCE":            winnerName,
            "SOURCE_BUNDLE":     winner.bundle,
            "TIMEZONE":          winner.timezone ?? TimeZone.current.identifier,
            "TOTAL_SLEEP":       Int(totalSleep),
            "SLEEP_IN_BED":      Int(winner.inBed),
            "SLEEP_LIGHT":       Int(winner.core),
            "SLEEP_DEEP":        Int(winner.deep),
            "SLEEP_REM":         Int(winner.rem),
            "SLEEP_UNSPECIFIED": Int(winner.unspecified),
            "SLEEP_AWAKE":       Int(winner.awake),
            "BED_TIME":          winner.minStart.map { isoFormatter.string(from: $0) } as Any,
            "WAKE_TIME":         winner.maxEnd.map   { isoFormatter.string(from: $0) } as Any,
            "START_DATE":        isoFormatter.string(from: queryStart),
            "END_DATE":          isoFormatter.string(from: queryEnd)
        ]
    }

    // MARK: - Raw snapshot (for local cache)

    /// Builds the legacy raw snapshot format (used for fetchStoredSleepData compatibility).
    private func buildRawSnapshot(samples: [HKCategorySample], queryStart: Date, queryEnd: Date) -> [String: Any] {
        var sleepSamples: [[String: Any]] = []
        var totalSleepSeconds: Double = 0
        var stageTotals: [String: Double] = ["inBed": 0, "asleepUnspecified": 0, "awake": 0, "asleepCore": 0, "asleepDeep": 0, "asleepREM": 0]

        for sample in samples {
            let sampleDict = convertSampleToDict(sample)
            sleepSamples.append(sampleDict)
            let dur = sample.endDate.timeIntervalSince(sample.startDate)
            let stage = sleepStageString(from: sample.value)
            stageTotals[stage, default: 0] += dur
            if stage != "inBed" && stage != "awake" { totalSleepSeconds += dur }
        }
        return [
            "samples": sleepSamples,
            "sampleCount": samples.count,
            "totalSleepSeconds": totalSleepSeconds,
            "totalSleepMinutes": totalSleepSeconds / 60.0,
            "totalSleepHours": totalSleepSeconds / 3600.0,
            "stageTotals": stageTotals.mapValues { ["seconds": $0, "minutes": $0 / 60.0] },
            "fetchedFrom": isoFormatter.string(from: queryStart),
            "fetchedTo": isoFormatter.string(from: queryEnd)
        ]
    }

    private func logPayload(_ payload: [String: Any]) {
        let totalMin = (payload["TOTAL_SLEEP"] as? Int ?? 0) / 60
        let lightMin = (payload["SLEEP_LIGHT"] as? Int ?? 0) / 60
        let deepMin  = (payload["SLEEP_DEEP"]  as? Int ?? 0) / 60
        let remMin   = (payload["SLEEP_REM"]   as? Int ?? 0) / 60
        let awakeMin = (payload["SLEEP_AWAKE"] as? Int ?? 0) / 60
        let inBedMin = (payload["SLEEP_IN_BED"] as? Int ?? 0) / 60
        debugPrint("🛏️ [SleepDataManager] ── PAYLOAD ──────────────────────────")
        debugPrint("🛏️  SOURCE       : \(payload["SOURCE"] ?? "") (\(payload["SOURCE_BUNDLE"] ?? ""))")
        debugPrint("🛏️  TIMEZONE     : \(payload["TIMEZONE"] ?? "")")
        debugPrint("🛏️  TOTAL_SLEEP  : \(totalMin) min")
        debugPrint("🛏️  Light/Deep/REM: \(lightMin)m / \(deepMin)m / \(remMin)m")
        debugPrint("🛏️  AWAKE        : \(awakeMin) min")
        debugPrint("🛏️  IN_BED       : \(inBedMin) min")
        debugPrint("🛏️  BED_TIME     : \(payload["BED_TIME"] ?? "")")
        debugPrint("🛏️  WAKE_TIME    : \(payload["WAKE_TIME"] ?? "")")
        debugPrint("🛏️  START_DATE   : \(payload["START_DATE"] ?? "")")
        debugPrint("🛏️  END_DATE     : \(payload["END_DATE"] ?? "")")
        debugPrint("🛏️ ─────────────────────────────────────────────────")
    }
    
    /// Checks whether HealthKit has an active inBed sample that spans the current moment.
    /// Returns true  → user is currently in bed (session still in progress).
    /// Returns false → no current inBed coverage → proceed with payload delivery.
    private func isUserCurrentlyInBed() async -> Bool {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return false }
        let now = Date()
        let overlapPredicate = HKQuery.predicateForSamples(withStart: now, end: now, options: [])
        let inBedPredicate = HKQuery.predicateForCategorySamples(
            with: .equalTo,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue
        )
        let combined = NSCompoundPredicate(andPredicateWithSubpredicates: [overlapPredicate, inBedPredicate])
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType, predicate: combined, limit: 1, sortDescriptors: nil) { _, results, error in
                if let error = error {
                    debugPrint("🛏️ [SleepDataManager] isUserCurrentlyInBed error: \(error)")
                    cont.resume(returning: false)
                    return
                }
                cont.resume(returning: !(results ?? []).isEmpty)
            }
            self.healthStore.execute(q)
        }
    }
    
    // MARK: - UserDefaults Storage

    private func storeSleepDataToUserDefaults(_ sleepData: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sleepData, options: [])
            UserDefaults.standard.set(jsonData, forKey: SleepDataKeys.storedSleepData)
            UserDefaults.standard.set(Date(), forKey: SleepDataKeys.lastFetchDate)
            debugPrint("🛏️ [SleepDataManager] cache saved to UserDefaults")
        } catch {
            debugPrint("🛏️ [SleepDataManager] UserDefaults serialize error: \(error)")
        }
    }
    
    private func fetchStoredSleepDataFromUserDefaults() -> [String: Any] {
        guard let jsonData = UserDefaults.standard.data(forKey: SleepDataKeys.storedSleepData) else {
            return [
                "samples": [],
                "sampleCount": 0,
                "totalSleepSeconds": 0,
                "totalSleepMinutes": 0,
                "totalSleepHours": 0,
                "stageTotals": [:],
                "storedAt": nil as Any?,
                "hasData": false
            ]
        }
        
        do {
            if var sleepData = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                if let storedDate = UserDefaults.standard.object(forKey: SleepDataKeys.lastFetchDate) as? Date {
                    sleepData["storedAt"] = isoFormatter.string(from: storedDate)
                }
                sleepData["hasData"] = true
                return sleepData
            }
        } catch {
            debugPrint("🛏️ [SleepDataManager] UserDefaults deserialize error: \(error)")
        }
        
        return ["samples": [], "sampleCount": 0, "hasData": false]
    }
    
    private func clearStoredSleepData() {
        UserDefaults.standard.removeObject(forKey: SleepDataKeys.storedSleepData)
        UserDefaults.standard.removeObject(forKey: SleepDataKeys.lastFetchDate)
        debugPrint("🛏️ [SleepDataManager] cleared UserDefaults cache")
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
