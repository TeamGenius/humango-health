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

        case "calculateSleepPayload":
            handleCalculateSleepPayload(call, result: result)
            
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
        isBackgroundMonitoring = false
        debugPrint("🛏️ [SleepDataManager] stopped background monitoring")
    }

    // MARK: - Background Observer Logic

    /// Core logic executed on every HKObserverQuery fire.
    ///
    /// Simplified pipeline (Issues 3 & 4):
    ///   Every observer fire → compute 6PM window → fetch samples
    ///   → calculateSleepPayload → store payload in UserDefaults.
    /// No inBed check, no 15-min timer, no raw-sample cache.
    /// Deduplication is the responsibility of the client app.
    private func handleBackgroundObserverFired() async {
        let pipelineStartTime = isoFormatter.string(from: Date())

        // ── STEP 1: Compute 6PM query window ──────────────────────────────────
        let (queryStart, queryEnd) = sixPMWindow()
        let windowStartStr = isoFormatter.string(from: queryStart)
        let windowEndStr   = isoFormatter.string(from: queryEnd)
        debugPrint("🛏️ [SleepDataManager] [STEP 1] 6PM window: \(windowStartStr) → \(windowEndStr)")
        await SleepRemoteLogger.shared.log(
            level: .info,
            message: "[STEP 1] 6PM query window computed",
            context: ["step": "window_computed", "windowStart": windowStartStr, "windowEnd": windowEndStr]
        )

        // ── STEP 2: Fetch sleep samples from HealthKit ────────────────────────
        let rawSamples: [HKCategorySample]
        do {
            rawSamples = try await fetchSleepSamples(from: queryStart, to: queryEnd)
        } catch {
            debugPrint("🛏️ [SleepDataManager] [STEP 2] HealthKit fetch failed: \(error)")
            await SleepRemoteLogger.shared.log(
                level: .error,
                message: "[STEP 2] HealthKit fetchSleepSamples threw an error",
                context: ["step": "hk_fetch_failed", "error": error.localizedDescription]
            )
            return
        }

        debugPrint("🛏️ [SleepDataManager] [STEP 2] HealthKit returned \(rawSamples.count) samples")

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
                ? "[STEP 2] No sleep samples found in 6PM window"
                : "[STEP 2] HealthKit samples fetched successfully",
            context: [
                "step": "hk_fetch_complete",
                "sampleCount": rawSamples.count,
                "stageCounts": stageCounts,
                "sources": Array(sourcesFound).sorted()
            ]
        )

        guard !rawSamples.isEmpty else {
            debugPrint("🛏️ [SleepDataManager] [STEP 2] no samples in window — nothing to do")
            return
        }

        // ── STEP 3: Calculate payload and store ───────────────────────────────
        await deliverPayload(samples: rawSamples,
                             queryStart: queryStart,
                             queryEnd: queryEnd,
                             sourcesFound: sourcesFound,
                             stageCounts: stageCounts,
                             trigger: "observer",
                             pipelineStartTime: pipelineStartTime)
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

        // Build flat aggregated payload using the group-based session detection algorithm:
        // sorts by startDate → groups by ≤2h gap → discards sessions <3h span →
        // picks winning source (highest Core+Deep+REM) → ceiling-rounds all durations.
        guard let payload = calculateSleepPayload(from: samples) else {
            debugPrint("🛏️ [SleepDataManager] [\(trigger.uppercased())] calculateSleepPayload=nil (no valid sleep groups ≥ 3h)")
            await SleepRemoteLogger.shared.log(
                level: .warn,
                message: "[\(trigger.uppercased())] Could not build payload — no valid sleep groups (all < 3h span)",
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
            "TOTAL_SLEEP":       Int(totalSleep.rounded(.up)),
            "SLEEP_IN_BED":      Int(winner.inBed.rounded(.up)),
            "SLEEP_LIGHT":       Int(winner.core.rounded(.up)),
            "SLEEP_DEEP":        Int(winner.deep.rounded(.up)),
            "SLEEP_REM":         Int(winner.rem.rounded(.up)),
            "SLEEP_UNSPECIFIED": Int(winner.unspecified.rounded(.up)),
            "SLEEP_AWAKE":       Int(winner.awake.rounded(.up)),
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
