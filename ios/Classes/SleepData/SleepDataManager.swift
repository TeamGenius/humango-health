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
    }

    deinit {
        AppLifecycleManager.shared.removeObserver(self)
    }
    
    // MARK: - Start / Stop Monitoring

    /// Starts sleep monitoring. Call this on every app open after `HumangoHealthPlugin.delegate` is set.
    /// Idempotent — if monitoring is already running, this is a no-op.
    public func startMonitoring() {
        guard monitorStartDate == nil else {
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

    }

    /// Stops all active monitoring and clears all persisted sleep data and configuration.
    /// Called on user logout to ensure no background activity continues and data is wiped.
    func stopAndClearAll() {
  
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil

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
                } catch {
                }
            }
        }
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
                    result(sleepData?.toDict())
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
                let serialised: [[String: Any]] = samples.map { self.convertSampleToHuSleepSample($0).toDict(formatter: self.isoFormatter) }
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
    func fetchSleepData(startDate: Date? = nil, endDate: Date? = nil) async throws -> HuSleepSession? {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "SleepData", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HealthKit is not available on this device"
            ])
        }

        let queryEndDate   = endDate   ?? Date()
        let queryStartDate = startDate ?? Calendar.current.date(byAdding: .hour, value: -24, to: queryEndDate)!

        // Single canonical HealthKit query path shared with the monitoring pipeline.
        let rawSamples = try await fetchSleepSamples(from: queryStartDate, to: queryEndDate)

        guard !rawSamples.isEmpty else {
            return nil
        }

        // Delegate all duration/aggregation logic to calculateSleepPayload —
        // this applies the Apple-source filter, gap-based session grouping,
        // and stage-level totals, identical to the background monitoring path.
        guard let payload = calculateSleepPayload(from: rawSamples) else {
            return nil
        }

        let totalSleepSeconds = payload["TOTAL_SLEEP"]       as? Double ?? 0
        let sleepInBed        = payload["SLEEP_IN_BED"]      as? Double ?? 0
        let sleepCore         = payload["SLEEP_LIGHT"]        as? Double ?? 0
        let sleepDeep         = payload["SLEEP_DEEP"]         as? Double ?? 0
        let sleepREM          = payload["SLEEP_REM"]          as? Double ?? 0
        let sleepUnspecified  = payload["SLEEP_UNSPECIFIED"]  as? Double ?? 0
        let sleepAwake        = payload["SLEEP_AWAKE"]        as? Double ?? 0
        let sourceName        = payload["SOURCE"]             as? String ?? ""
        let sourceBundle      = payload["SOURCE_BUNDLE"]      as? String ?? ""
        let timezone          = payload["TIMEZONE"]           as? String ?? TimeZone.current.identifier
        let bedTimeStr        = payload["BED_TIME"]           as? String
        let wakeTimeStr       = payload["WAKE_TIME"]          as? String
        let bedTime           = bedTimeStr.flatMap  { isoFormatter.date(from: $0) }
        let wakeTime          = wakeTimeStr.flatMap { isoFormatter.date(from: $0) }
        let sessionId         = bedTimeStr ?? isoFormatter.string(from: queryStartDate)

        // Keep returned per-sample list aligned with the source selection used to
        // compute payload totals.
        let selectedBundle = sourceBundle.lowercased()
        let filteredSamples: [HKCategorySample]
        if selectedBundle.hasPrefix("com.apple.health") {
            filteredSamples = rawSamples.filter {
                $0.sourceRevision.source.bundleIdentifier.lowercased().hasPrefix("com.apple.health")
            }
        } else if !selectedBundle.isEmpty {
            filteredSamples = rawSamples.filter {
                $0.sourceRevision.source.bundleIdentifier == sourceBundle
            }
        } else {
            filteredSamples = rawSamples
        }
        let huSamples = filteredSamples.map { convertSampleToHuSleepSample($0) }


        return HuSleepSession(
            source:                  sourceName,
            sourceBundle:            sourceBundle,
            timezone:                timezone,
            totalSleepSeconds:       totalSleepSeconds,
            sleepInBedSeconds:       sleepInBed,
            sleepLightSeconds:       sleepCore,
            sleepDeepSeconds:        sleepDeep,
            sleepREMSeconds:         sleepREM,
            sleepUnspecifiedSeconds: sleepUnspecified,
            sleepAwakeSeconds:       sleepAwake,
            bedTime:                 bedTime,
            wakeTime:                wakeTime,
            queryStart:              queryStartDate,
            queryEnd:                queryEndDate,
            sessionId:               sessionId,
            samples:                 huSamples
        )
    }
    
    // MARK: - Foreground Monitoring (HKAnchoredObjectQueryDescriptor)
    
    /// Foreground monitoring via HKAnchoredObjectQueryDescriptor (iOS 15+).
    /// On each new batch of samples, fetches the full 6PM window and stores to local cache.
    /// Delivery to backend only happens via the background observer path.
    private func startLiveUpdates() {
        guard !isLiveStreaming else { return }
        guard let startDate = monitorStartDate else { return }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
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
                        }
                        for deleted in update.deletedObjects {
                        }
                    }
                } catch {

                }
            }
        } else {
        }
    }

    private func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        isLiveStreaming = false
    }
    
    // MARK: - Background Monitoring

    /// Starts background monitoring using HKObserverQuery.
    /// On every fire: compute 6PM window → fetch samples → calculateSleepPayload → delegate.onSleepSessionReady.
    private func startBackgroundMonitoring() {
        guard !isBackgroundMonitoring else { return }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return
        }

        isBackgroundMonitoring = true

        Task {
            do {
                try await healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate)
            } catch {
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
                completion()
                return
            }

            Task {
                await self.handleBackgroundObserverFired()
                // Signal HealthKit AFTER all async work is complete so iOS keeps
                // the app alive for the full fetch → compute → deliver pipeline.
                completion()
            }
        }

        if let query = observerQuery {
            healthStore.execute(query)
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
    }

    // MARK: - Background Observer Logic

    private func handleBackgroundObserverFired() async {
        let (queryStart, queryEnd) = sixPMWindow()


        let rawSamples: [HKCategorySample]
        do {
            rawSamples = try await fetchSleepSamples(from: queryStart, to: queryEnd)
        } catch {
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

        let bedTimeStr   = payload["BED_TIME"]      as? String
        let wakeTimeStr  = payload["WAKE_TIME"]     as? String
        let sessionId    = bedTimeStr ?? isoFormatter.string(from: queryStart)

        let session = HuSleepSession(
            source:                  payload["SOURCE"]        as? String ?? "",
            sourceBundle:            payload["SOURCE_BUNDLE"] as? String ?? "",
            timezone:                payload["TIMEZONE"]      as? String ?? TimeZone.current.identifier,
            totalSleepSeconds:       payload["TOTAL_SLEEP"]       as? Double ?? 0,
            sleepInBedSeconds:       payload["SLEEP_IN_BED"]      as? Double ?? 0,
            sleepLightSeconds:       payload["SLEEP_LIGHT"]        as? Double ?? 0,
            sleepDeepSeconds:        payload["SLEEP_DEEP"]         as? Double ?? 0,
            sleepREMSeconds:         payload["SLEEP_REM"]          as? Double ?? 0,
            sleepUnspecifiedSeconds: payload["SLEEP_UNSPECIFIED"]  as? Double ?? 0,
            sleepAwakeSeconds:       payload["SLEEP_AWAKE"]        as? Double ?? 0,
            bedTime:                 bedTimeStr.flatMap  { isoFormatter.date(from: $0) },
            wakeTime:                wakeTimeStr.flatMap { isoFormatter.date(from: $0) },
            queryStart:              queryStart,
            queryEnd:                queryEnd,
            sessionId:               sessionId,
            samples:                 []
        )

        if let delegate = HumangoHealthPlugin.delegate {
            // `await` so the host app's upload completes before we return.
            // completion() is called after this function returns, so iOS keeps
            // the app alive for the full fetch → compute → upload pipeline.
            await delegate.onSleepSessionReady(session)
        } else {
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

        // --- Group by source name (normalized: Apple-platform sources → "Apple") ---
        var bySource: [String: [HKCategorySample]] = [:]
        for s in samples {
            let name = HealthKitConverter.normalizedSourceName(
                name: s.sourceRevision.source.name,
                bundle: s.sourceRevision.source.bundleIdentifier
            )
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
    /// Tier-2 preference order when Apple-platform samples are absent.
    private static let tier2PreferredBundles: [String] = [
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
    ///   Tier 2 — If Apple is absent, evaluate known fitness-tracker bundles in the
    ///             configured order and return the first bundle that yields a valid payload.
    ///   Tier 3 — If no Tier-2 bundle yields a valid payload, evaluate remaining bundles
    ///             (non-Tier-2) and return the first valid payload.
    ///
    /// Exactly one source bundle is selected; samples from different bundles are never mixed.
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

        logFetchedSamplesBeforeLogic(samples)

        // ── Tier 1: Apple-platform source priority ─────────────────────────────
        let appleSamples = samples.filter {
            $0.sourceRevision.source.bundleIdentifier.lowercased().hasPrefix("com.apple.health")
        }
        if !appleSamples.isEmpty {
            let droppedCount = samples.count - appleSamples.count
            if droppedCount > 0 {
                let droppedBundles = Set(
                    samples
                        .filter { !$0.sourceRevision.source.bundleIdentifier.lowercased().hasPrefix("com.apple.health") }
                        .map { $0.sourceRevision.source.bundleIdentifier }
                )
            }
            return runGroupingAndCalculation(on: appleSamples, label: "Apple")
        }

        // ── Tier 2 + Tier 3: Candidate-order selection among non-Apple bundles ─
        let nonAppleSamples = samples.filter {
            !$0.sourceRevision.source.bundleIdentifier.lowercased().hasPrefix("com.apple.health")
        }
        guard !nonAppleSamples.isEmpty else {
            return nil
        }

        let byBundle = Dictionary(grouping: nonAppleSamples) { $0.sourceRevision.source.bundleIdentifier }
        let presentBundles = Array(byBundle.keys)

        let tier2 = Self.tier2PreferredBundles
        func tier2Rank(for bundle: String) -> Int? {
            let lower = bundle.lowercased()
            return tier2.firstIndex(where: { lower.hasPrefix($0) })
        }
        func firstStartDate(for bundle: String) -> Date {
            byBundle[bundle]?.map(\.startDate).min() ?? .distantFuture
        }

        let tier2Bundles = presentBundles
            .filter { tier2Rank(for: $0) != nil }
            .sorted { lhs, rhs in
                let lRank = tier2Rank(for: lhs)!
                let rRank = tier2Rank(for: rhs)!
                if lRank != rRank { return lRank < rRank }
                return firstStartDate(for: lhs) < firstStartDate(for: rhs)
            }

        let otherBundles = presentBundles
            .filter { tier2Rank(for: $0) == nil }
            .sorted { lhs, rhs in
                firstStartDate(for: lhs) < firstStartDate(for: rhs)
            }

        let orderedCandidates = tier2Bundles + otherBundles

        for bundle in orderedCandidates {
            guard let bundleSamples = byBundle[bundle] else { continue }
            guard let payload = runGroupingAndCalculation(on: bundleSamples, label: bundle) else {
                continue
            }
            let totalSleep = payload["TOTAL_SLEEP"] as? Double ?? 0
            return payload
        }

        return nil
    }

    private func logFetchedSamplesBeforeLogic(_ samples: [HKCategorySample]) {
        let sorted = samples.sorted { lhs, rhs in
            if lhs.startDate == rhs.startDate {
                return lhs.endDate < rhs.endDate
            }
            return lhs.startDate < rhs.startDate
        }

        _ = sorted
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
            return nil
        }

        let validSamples = validGroups.flatMap { $0 }

        // ── Step 3: Merge valid groups → build aggregated payload ──────────────
        // queryStart: earliest startDate (.first is correct — sorted is by startDate)
        // queryEnd:   latest endDate across ALL valid samples — must use max(endDate),
        //             not .last!.endDate, for the same reason as the span filter above.
        let queryStart = validSamples.first!.startDate
        let queryEnd   = validSamples.max(by: { $0.endDate < $1.endDate })!.endDate

        return buildAggregatedPayload(samples: validSamples, queryStart: queryStart, queryEnd: queryEnd)
    }

    // MARK: - Convert Sample to HuSleepSample

    private func convertSampleToHuSleepSample(_ sample: HKCategorySample) -> HuSleepSample {
        let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
        let stageName = sleepStageString(from: sample.value)

        // Device
        let huDevice: HuSleepDevice? = sample.device.map {
            HuSleepDevice(
                name:             $0.name,
                model:            $0.model,
                manufacturer:     $0.manufacturer,
                hardwareVersion:  $0.hardwareVersion,
                softwareVersion:  $0.softwareVersion,
                localIdentifier:  $0.localIdentifier
            )
        }

        // Metadata — convert to JSON-safe types
        var metadataDict: [String: Any]? = nil
        if let metadata = sample.metadata, !metadata.isEmpty {
            var d = [String: Any]()
            for (key, value) in metadata {
                if let v = value as? String       { d[key] = v }
                else if let v = value as? NSNumber { d[key] = v }
                else if let v = value as? Date     { d[key] = isoFormatter.string(from: v) }
                else                               { d[key] = String(describing: value) }
            }
            metadataDict = d
        }

        return HuSleepSample(
            uuid:            sample.uuid.uuidString,
            startDate:       sample.startDate,
            endDate:         sample.endDate,
            value:           sample.value,
            sleepStage:      stageName,
            durationSeconds: durationSeconds,
            sourceName:      HealthKitConverter.normalizedSourceName(name: sample.sourceRevision.source.name, bundle: sample.sourceRevision.source.bundleIdentifier),
            sourceBundle:    sample.sourceRevision.source.bundleIdentifier,
            device:          huDevice,
            metadata:        metadataDict
        )
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
