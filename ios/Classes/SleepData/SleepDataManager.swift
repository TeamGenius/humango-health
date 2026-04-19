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
    public static let shared = SleepDataManager()
    
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

    // MARK: - Initialization
    
    private override init() {
        super.init()
        AppLifecycleManager.shared.addObserver(self)
        debugPrint("🛏️ [SleepDataManager] initialized")
    }

    deinit {
        AppLifecycleManager.shared.removeObserver(self)
    }
    
    // MARK: - Start / Stop Monitoring

    /// Starts sleep monitoring. Call this on every app open after `HumangoHealthPlugin.delegate` is set.
    /// Idempotent — if monitoring is already running, this is a no-op.
    public func startMonitoring() {
        guard monitorStartDate == nil else {
            debugPrint("🛏️ [SleepDataManager] startMonitoring skipped — monitoring already active")
            return
        }

        let startDate = Date().addingTimeInterval(-12 * 60 * 60)
        monitorStartDate = startDate

        let mode = AppLifecycleManager.shared.isInForeground ? "foreground" : "background"

        if AppLifecycleManager.shared.isInForeground {
           
            startLiveUpdates()
        } else {
            startBackgroundMonitoring()
        }

        debugPrint("🛏️ [SleepDataManager] ✅ monitoring started (\(mode)) from \(isoFormatter.string(from: startDate))")
    }

    /// Stops all active monitoring and clears all persisted sleep data and configuration.
    /// Called on user logout to ensure no background activity continues and data is wiped.
    func stopAndClearAll() {
  
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil
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
        // Re-register background delivery on every foreground→background transition.
        // enableBackgroundDelivery persists the HealthKit wake-up registration so iOS
        // wakes the app when new sleep data arrives while suspended.
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            Task {
                do {
                    try await self.healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate)
                    debugPrint("🛏️ [SleepDataManager] switchToBackgroundMode — re-registered background delivery")
                } catch {
                    debugPrint("🛏️ [SleepDataManager] switchToBackgroundMode — re-register failed: \(error)")
                }
            }
        }
        debugPrint("🛍️ [SleepDataManager] → background mode")
    }
    
    // MARK: - Method Channel Handler
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method
        switch method {
        case "getSleepData":
            handleGetSleepData(call, result: result)

        case "calculateSleepPayload":
            handleCalculateSleepPayload(call, result: result)

        case "fetchSleepSamples":
            handleFetchSleepSamples(call, result: result)

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
    
    /// Exposes `fetchSleepSamples(from:to:)` over the Flutter method channel.
    /// Returns the raw HealthKit `HKCategorySample` array serialised as a list of
    /// sample dictionaries — the same shape as the `samples` array inside
    /// `getSleepData`, but without any aggregation.
    private func handleFetchSleepSamples(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
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

        let queryEndDate   = endDate   ?? Date()
        let queryStartDate = startDate ?? Calendar.current.date(byAdding: .hour, value: -24, to: queryEndDate)!

        Task {
            do {
                let samples = try await fetchSleepSamples(from: queryStartDate, to: queryEndDate)
                let serialised: [[String: Any]] = samples.map { self.convertSampleToDict($0) }
                DispatchQueue.main.async {
                    result(serialised)
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

        let queryEndDate   = endDate   ?? Date()
        let queryStartDate = startDate ?? Calendar.current.date(byAdding: .hour, value: -24, to: queryEndDate)!

        // Single canonical HealthKit query path shared with the monitoring pipeline.
        let rawSamples = try await fetchSleepSamples(from: queryStartDate, to: queryEndDate)

        // Delegate all duration/aggregation logic to calculateSleepPayload —
        // this applies the Apple-source filter, gap-based session grouping,
        // and stage-level totals, identical to the background monitoring path.
        let payload = calculateSleepPayload(from: rawSamples)

        let totalSleepSeconds = payload?["TOTAL_SLEEP"]       as? Double ?? 0
        let sleepInBed        = payload?["SLEEP_IN_BED"]      as? Double ?? 0
        let sleepCore         = payload?["SLEEP_LIGHT"]        as? Double ?? 0
        let sleepDeep         = payload?["SLEEP_DEEP"]         as? Double ?? 0
        let sleepREM          = payload?["SLEEP_REM"]          as? Double ?? 0
        let sleepUnspecified  = payload?["SLEEP_UNSPECIFIED"]  as? Double ?? 0
        let sleepAwake        = payload?["SLEEP_AWAKE"]        as? Double ?? 0

        // Build the per-sample list using the same Apple-source filter applied
        // internally by calculateSleepPayload so sample list and totals are consistent.
        let appleSamples = rawSamples.filter {
            $0.sourceRevision.source.bundleIdentifier.hasPrefix("com.apple.health")
        }
        let filteredSamples: [HKCategorySample] = appleSamples.isEmpty ? rawSamples : appleSamples
        let sleepSamples = filteredSamples.map { convertSampleToDict($0) }

        debugPrint("🛏️ [SleepDataManager] fetchSleepData: \(filteredSamples.count) samples (raw=\(rawSamples.count)) totalSleep=\(Int(totalSleepSeconds))s from \(isoFormatter.string(from: queryStartDate)) to \(isoFormatter.string(from: queryEndDate))")

        return [
            "samples":            sleepSamples,
            "sampleCount":        filteredSamples.count,
            "totalSleepSeconds":  totalSleepSeconds,
            "totalSleepMinutes":  totalSleepSeconds / 60.0,
            "totalSleepHours":    totalSleepSeconds / 3600.0,
            "stageTotals": [
                "inBed":             ["seconds": sleepInBed,        "minutes": sleepInBed        / 60.0],
                "asleepUnspecified": ["seconds": sleepUnspecified,  "minutes": sleepUnspecified  / 60.0],
                "awake":             ["seconds": sleepAwake,        "minutes": sleepAwake        / 60.0],
                "asleepCore":        ["seconds": sleepCore,         "minutes": sleepCore         / 60.0],
                "asleepDeep":        ["seconds": sleepDeep,         "minutes": sleepDeep         / 60.0],
                "asleepREM":         ["seconds": sleepREM,          "minutes": sleepREM          / 60.0],
            ] as [String: Any],
            "fetchedFrom": isoFormatter.string(from: queryStartDate),
            "fetchedTo":   isoFormatter.string(from: queryEndDate)
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
            // NOTE: Do NOT use `defer { completion() }` here.
            // completion() must be called AFTER the async delivery work finishes so iOS
            // does not suspend the app before fetchSleepSamples / deliverPayload / the
            // remote log network request complete.

            let fireTime = self.isoFormatter.string(from: Date())

            if let error = error {
                debugPrint("🛏️ [SleepDataManager] observer error at \(fireTime): \(error)")
                completion()
                return
            }

            debugPrint("🛏️ [SleepDataManager] observer fired at \(fireTime) — processing")
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
        // NOTE: We intentionally do NOT call disableBackgroundDelivery here.
        // Background delivery must remain persistently enabled so HealthKit can relaunch
        // the app and fire the observer after a kill+reopen cycle. Calling disable on
        // every foreground transition creates a race where the async re-enable never wins
        // and delivery is permanently broken.
        isBackgroundMonitoring = false
        debugPrint("🛏️ [SleepDataManager] stopped background monitoring")
    }

    // MARK: - Background Observer Logic

    private func handleBackgroundObserverFired() async {
        let (queryStart, queryEnd) = sixPMWindow()


        let rawSamples: [HKCategorySample]
        do {
            rawSamples = try await fetchSleepSamples(from: queryStart, to: queryEnd)
        } catch {
            debugPrint("🛏️ [SleepDataManager] background fetch failed: \(error)")
            return
        }

        guard !rawSamples.isEmpty else {
            return
        }

        await deliverPayload(samples: rawSamples, queryStart: queryStart, queryEnd: queryEnd)
    }

    // MARK: - Payload Delivery

    func deliverPayload(samples: [HKCategorySample], queryStart: Date, queryEnd: Date) async {
        
        guard let payload = calculateSleepPayload(from: samples) else {
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            debugPrint("🛏️ [SleepDataManager] deliverPayload: serialization failed")
            return
        }

        let sessionId = payload["BED_TIME"] as? String ?? isoFormatter.string(from: queryStart)

        if let delegate = HumangoHealthPlugin.delegate {
            // `await` so the host app's upload completes before we return.
            // completion() is called after this function returns, so iOS keeps
            // the app alive for the full fetch → compute → upload pipeline.
            await delegate.onSleepSessionReady(json: jsonString, sessionId: sessionId)
        } else {
            debugPrint("⚠️ [SleepDataManager] delegate is nil — sleep session \(sessionId) not delivered")
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

    func fetchSleepSamples(from start: Date, to end: Date) async throws -> [HKCategorySample] {
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
                for (i, s) in samples.enumerated() {
                    let dur = s.endDate.timeIntervalSince(s.startDate)
                    let stage: String
                    switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                    case .inBed:             stage = "inBed"
                    case .asleepUnspecified: stage = "asleepUnspecified"
                    case .awake:             stage = "awake"
                    case .asleepCore:        stage = "asleepCore"
                    case .asleepDeep:        stage = "asleepDeep"
                    case .asleepREM:         stage = "asleepREM"
                    default:                 stage = "unknown(\(s.value))"
                    }
                    debugPrint("🛏️ [SleepDataManager]   [\(i)] \(stage) | \(self.isoFormatter.string(from: s.startDate)) → \(self.isoFormatter.string(from: s.endDate)) | \(Int(dur / 60))m | src=\(s.sourceRevision.source.name) (\(s.sourceRevision.source.bundleIdentifier))")
                }
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
    ///
    /// Source priority: if ANY sample originates from an Apple-platform source
    /// (bundle prefix `com.apple.health`) — which covers both the user's Apple Watch
    /// (`com.apple.health.<device-UUID>`) and the iPhone Health app (`com.apple.health`)
    /// regardless of the user-visible device name — all third-party samples are discarded
    /// before aggregation. If no Apple samples exist, all samples are used (third-party only).
    private func buildAggregatedPayload(samples: [HKCategorySample], queryStart: Date, queryEnd: Date) -> [String: Any]? {
        // Note: Apple-platform source priority filtering is applied upstream in
        // calculateSleepPayload before this function is called. All samples
        // passed here are already from a single source tier.

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

    /// Source bundle prefixes for known fitness-tracker apps.
    /// Excluded from consideration when no Apple-platform samples are present (Tier 2).
    private static let excludedThirdPartyBundles: [String] = [
        "com.whoop",
        "com.garmin.connect",
        "com.ouraring.oura",
        "com.coros.coros",
        "com.fitbit",
        "com.sram.hammerhead",
        "com.hammerhead",
        "fi.polar",
        "com.polar",
        "com.sports-tracker.suunto",
        "com.suunto",
        "com.wahoo",
    ]

    /// Calculates a flat aggregated sleep payload directly from a list of raw HealthKit samples.
    ///
    /// Source-priority tiers (applied in order):
    ///   Tier 1 — Apple-platform samples (`com.apple.health` prefix): if any exist, use ONLY
    ///             those and return immediately. No other sources are considered.
    ///   Tier 2 — Known fitness-tracker bundles (Whoop, Garmin, Oura, Coros, Fitbit, etc.)
    ///             are stripped from the remaining pool.
    ///   Tier 3 — Group remaining samples by `sourceBundle` and calculate a payload
    ///             independently per bundle. Return the payload with the highest TOTAL_SLEEP.
    ///             Samples from two different bundle IDs are NEVER mixed.
    ///
    /// Gap-grouping algorithm (applied per bundle):
    ///   Step 1 — Sort samples by `startDate` ascending.
    ///   Step 2 — Group consecutive samples where the gap between
    ///             `sample[i].startDate` and `sample[i-1].endDate` is ≤ 2 hours.
    ///             Any group whose span (first.startDate → max(endDate)) is < 3 hours
    ///             is discarded as a nap or data artifact.
    ///   Step 3 — Merge all valid groups and delegate to `buildAggregatedPayload`.
    ///
    /// - Parameter samples: Raw `HKCategorySample` array from HealthKit (any order).
    /// - Returns: Aggregated sleep payload, or `nil` if no valid sleep groups are found.
    func calculateSleepPayload(from samples: [HKCategorySample]) -> [String: Any]? {
        guard !samples.isEmpty else { return nil }

        // ── Tier 1: Apple-platform source priority ─────────────────────────────
        let appleSamples = samples.filter {
            $0.sourceRevision.source.bundleIdentifier.hasPrefix("com.apple.health")
        }
        if !appleSamples.isEmpty {
            let droppedCount = samples.count - appleSamples.count
            if droppedCount > 0 {
                let droppedBundles = Set(
                    samples
                        .filter { !$0.sourceRevision.source.bundleIdentifier.hasPrefix("com.apple.health") }
                        .map { $0.sourceRevision.source.bundleIdentifier }
                )
                debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: Tier 1 — dropped \(droppedCount) third-party sample(s) from: \(droppedBundles.joined(separator: ", "))")
            }
            debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: Tier 1 — using \(appleSamples.count) Apple sample(s)")
            return runGroupingAndCalculation(on: appleSamples, label: "Apple")
        }

        // ── Tier 2: Strip known fitness-tracker sources ────────────────────────
        let excluded = Self.excludedThirdPartyBundles
        let remaining = samples.filter { sample in
            let bundle = sample.sourceRevision.source.bundleIdentifier
            return !excluded.contains(where: { bundle.hasPrefix($0) })
        }
        if remaining.count < samples.count {
            let droppedBundles = Set(
                samples
                    .filter { sample in
                        let bundle = sample.sourceRevision.source.bundleIdentifier
                        return excluded.contains(where: { bundle.hasPrefix($0) })
                    }
                    .map { $0.sourceRevision.source.bundleIdentifier }
            )
            debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: Tier 2 — dropped fitness-tracker samples from: \(droppedBundles.joined(separator: ", "))")
        }
        guard !remaining.isEmpty else {
            debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: Tier 2 — all samples excluded, returning nil")
            return nil
        }

        // ── Tier 3: Per-bundle grouping; pick highest TOTAL_SLEEP ─────────────
        let byBundle = Dictionary(grouping: remaining) { $0.sourceRevision.source.bundleIdentifier }
        debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: Tier 3 — \(byBundle.keys.count) bundle(s): \(byBundle.keys.sorted().joined(separator: ", "))")

        var bestPayload: [String: Any]? = nil
        var bestTotalSleep: Double = -1

        for (bundle, bundleSamples) in byBundle {
            guard let payload = runGroupingAndCalculation(on: bundleSamples, label: bundle) else {
                debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: Tier 3 — bundle '\(bundle)' yielded no valid payload")
                continue
            }
            let totalSleep = payload["TOTAL_SLEEP"] as? Double ?? 0
            debugPrint("🛏️ [SleepDataManager] calculateSleepPayload: Tier 3 — bundle '\(bundle)' TOTAL_SLEEP=\(totalSleep)")
            if totalSleep > bestTotalSleep {
                bestTotalSleep = totalSleep
                bestPayload = payload
            }
        }

        return bestPayload
    }

    /// Runs the gap-grouping + span-filter + `buildAggregatedPayload` pipeline on a
    /// **single-source** sample array. All samples MUST share the same source bundle.
    ///
    /// - Parameters:
    ///   - samples: Samples from a single bundle (or the Apple-platform subset).
    ///   - label:   Debug label (bundle identifier or "Apple") used in log output.
    /// - Returns: Aggregated sleep payload, or `nil` if no valid sleep groups are found.
    private func runGroupingAndCalculation(on samples: [HKCategorySample], label: String) -> [String: Any]? {
        // ── Step 1: Sort by startDate ──────────────────────────────────────────
        let sorted = samples.sorted { $0.startDate < $1.startDate }

        // ── Step 2: Group consecutive samples (gap ≤ 2 hours) ─────────────────
        let maxGap: TimeInterval       = 2 * 60 * 60  // 2 hours
        let minGroupSpan: TimeInterval = 3 * 60 * 60  // 3 hours

        var groups: [[HKCategorySample]] = []
        var currentGroup: [HKCategorySample] = [sorted[0]]

        for i in 1 ..< sorted.count {
            let gap = sorted[i].startDate.timeIntervalSince(currentGroup.last!.endDate)
            if gap <= maxGap {
                currentGroup.append(sorted[i])
            } else {
                groups.append(currentGroup)
                currentGroup = [sorted[i]]
            }
        }
        groups.append(currentGroup)

        // Discard groups whose span < 3 hours (naps / data artifacts).
        // Use max(endDate) — NOT group.last!.endDate — because sorting is by startDate,
        // so the last sample by start may not have the latest end.
        let validGroups = groups.filter { group -> Bool in
            guard let first = group.first else { return false }
            let maxEnd = group.max(by: { $0.endDate < $1.endDate })!.endDate
            return maxEnd.timeIntervalSince(first.startDate) >= minGroupSpan
        }

        guard !validGroups.isEmpty else {
            debugPrint("🛏️ [SleepDataManager] [\(label)] runGroupingAndCalculation: no valid sleep groups (all < 3h span)")
            return nil
        }

        let validSamples = validGroups.flatMap { $0 }
        debugPrint("🛏️ [SleepDataManager] [\(label)] runGroupingAndCalculation: \(validGroups.count)/\(groups.count) group(s) valid, \(validSamples.count) sample(s)")

        // ── Step 3: Merge valid groups → build aggregated payload ──────────────
        // queryStart: earliest startDate (.first is correct — sorted is by startDate)
        // queryEnd:   latest endDate across ALL valid samples — must use max(endDate),
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
