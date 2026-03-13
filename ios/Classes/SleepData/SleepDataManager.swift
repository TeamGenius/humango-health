//
//  SleepDataManager.swift
//  humango_health
//
//  Fetches and monitors sleep data from Apple HealthKit
//  Supports: one-shot fetch, background monitoring (foreground Descriptor + background Observer)
//  Uses native iOS lifecycle detection via AppLifecycleManager for automatic mode switching
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
    
    // Sleep session detection (freeze window: 12 AM - 12 PM)
    private var sessionDetector: SleepSessionDetector
    private var sessionState: SleepSessionState = .empty
    private var freezeCheckTimer: Timer?
    
    // Background delivery manager (API vs localStorage mode)
    private let deliveryManager = SleepBackgroundDeliveryManager.shared
    
    // Configuration
    private var monitorStartDate: Date?
    private var sessionConfig: SleepSessionConfig = .default
    
    // MARK: - Initialization
    
    private override init() {
        self.sessionDetector = SleepSessionDetector(config: .default)
        super.init()
        // Register with AppLifecycleManager for automatic foreground/background switching
        AppLifecycleManager.shared.addObserver(self)
        // Restore persisted session state if any
        self.sessionState = sessionDetector.loadState()
        print("🛏️ [Humango Health] SleepDataManager initialized with native lifecycle observer")
        if sessionState.segmentCount > 0 {
            print("🛏️ [Humango Health] Restored session state: \(sessionState.segmentCount) segments, \(String(format: "%.0f", sessionState.totalSleepMinutes))m sleep")
        }
    }
    
    deinit {
        AppLifecycleManager.shared.removeObserver(self)
        freezeCheckTimer?.invalidate()
    }
    
    // MARK: - Auto-Start on App Launch
    
    /// Auto-starts sleep monitoring if API delivery is configured in UserDefaults.
    /// Called from HumangoHealthPlugin.register() on every app launch/background wake.
    /// First launch: no config in UserDefaults → no-op.
    /// Subsequent launches: config persisted from previous configureSleepBackgroundDelivery() call → auto-start.
    func autoStartIfConfigured() {
        guard UserAuthStateManager.shared.isLoggedIn else {
            print("🛏️ [Humango Health] Auto-start skipped — user not logged in")
            return
        }
        guard deliveryManager.isAPIConfigured else {
            print("🛏️ [Humango Health] Auto-start skipped — no API config in UserDefaults")
            return
        }
        guard monitorStartDate == nil else {
            print("🛏️ [Humango Health] Auto-start skipped — monitoring already active")
            return
        }
        
        let startDate = Date().addingTimeInterval(-12 * 60 * 60) // 12h lookback
        monitorStartDate = startDate
        
        if AppLifecycleManager.shared.isInForeground {
            startLiveUpdates()
        } else {
            startBackgroundMonitoring()
        }
        
        print("🛏️ [Humango Health] ✅ Auto-started sleep monitoring (API mode) from \(isoFormatter.string(from: startDate))")
    }

    /// Stops all active monitoring and clears all persisted sleep data and configuration.
    /// Called on user logout to ensure no background activity continues and data is wiped.
    func stopAndClearAll() {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil
        sessionState = .empty
        sessionDetector.clearState()
        clearStoredSleepData()
        deliveryManager.clearConfiguration()
        print("🛏️ [Humango Health] ✅ Stopped all sleep monitoring and cleared data on logout")
    }
    
    // MARK: - AppLifecycleObserver (Native iOS lifecycle)
    
    func appDidEnterForeground() {
        switchToForegroundMode()
    }
    
    func appDidEnterBackground() {
        switchToBackgroundMode()
    }
    
    // MARK: - Mode Switching (shared logic)
    
    /// Switches to foreground mode.
    /// Both API and localStorage modes use HKAnchoredObjectQueryDescriptor in foreground.
    /// - localStorage mode: pushes individual samples to Flutter EventChannel
    /// - API mode: accumulates samples into session state, triggers API on session end
    private func switchToForegroundMode() {
        guard monitorStartDate != nil else { return }
        
        stopBackgroundMonitoring()
        startLiveUpdates()
        print("🛏️ [Humango Health] Switched to foreground mode (Descriptor, delivery=\(deliveryManager.mode.rawValue)) via native lifecycle")
    }
    
    /// Switches to background mode.
    /// Both API and localStorage modes use HKObserverQuery in background.
    private func switchToBackgroundMode() {
        guard monitorStartDate != nil else { return }
        
        stopLiveUpdates()
        startBackgroundMonitoring()
        print("🛏️ [Humango Health] Switched to background mode (Observer, delivery=\(deliveryManager.mode.rawValue)) via native lifecycle")
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
            
        case "configureSleepSession":
            handleConfigureSleepSession(call, result: result)
            
        case "getSleepSessionStatus":
            handleGetSleepSessionStatus(result: result)
            
        case "resetSleepSession":
            handleResetSleepSession(result: result)
            
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
        
        print("🛏️ [Humango Health] Started sleep monitoring (delivery=\(deliveryManager.mode.rawValue)) from \(isoFormatter.string(from: startDate))")
        
        result(["status": "started", "startDate": isoFormatter.string(from: startDate), "deliveryMode": deliveryManager.mode.rawValue])
    }
    
    private func handleStopMonitoring(result: @escaping FlutterResult) {
        stopLiveUpdates()
        stopBackgroundMonitoring()
        monitorStartDate = nil
        
        print("🛏️ [Humango Health] Stopped sleep monitoring")
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
    
    private func handleConfigureSleepSession(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        var freezeStart = 0
        var freezeEnd = 12
        var minSleepMinutes = 240.0
        var stalenessMinutes = 60.0
        var deepAbsenceMinutes = 90.0
        
        if let args = call.arguments as? [String: Any] {
            if let start = args["freezeWindowStartHour"] as? Int { freezeStart = start }
            if let end = args["freezeWindowEndHour"] as? Int { freezeEnd = end }
            if let minSleep = args["minimumSleepMinutes"] as? Double { minSleepMinutes = minSleep }
            if let staleness = args["stalenessThresholdMinutes"] as? Double { stalenessMinutes = staleness }
            if let deepAbsence = args["deepSleepAbsenceWindowMinutes"] as? Double { deepAbsenceMinutes = deepAbsence }
        }
        
        sessionConfig = SleepSessionConfig(
            freezeWindowStartHour: freezeStart,
            freezeWindowEndHour: freezeEnd,
            minimumSleepMinutes: minSleepMinutes,
            stalenessThresholdMinutes: stalenessMinutes,
            deepSleepAbsenceWindowMinutes: deepAbsenceMinutes
        )
        sessionDetector = SleepSessionDetector(config: sessionConfig)
        
        print("🛏️ [Humango Health] Sleep session configured: freeze \(freezeStart):00-\(freezeEnd):00, minSleep=\(minSleepMinutes)m")
        result([
            "status": "configured",
            "freezeWindowStartHour": freezeStart,
            "freezeWindowEndHour": freezeEnd,
            "minimumSleepMinutes": minSleepMinutes,
            "stalenessThresholdMinutes": stalenessMinutes,
            "deepSleepAbsenceWindowMinutes": deepAbsenceMinutes
        ])
    }
    
    private func handleGetSleepSessionStatus(result: @escaping FlutterResult) {
        let status = sessionDetector.evaluateSession(state: sessionState)
        let isInFreeze = sessionDetector.isInFreezeWindow()
        
        var statusStr: String
        var reason: String = ""
        
        switch status {
        case .active:
            statusStr = "active"
        case .ended(let r):
            statusStr = "ended"
            reason = r
        case .freezeExpired:
            statusStr = "freeze_expired"
            reason = "Freeze window ended"
        }
        
        result([
            "status": statusStr,
            "reason": reason,
            "isInFreezeWindow": isInFreeze,
            "segmentCount": sessionState.segmentCount,
            "totalSleepMinutes": sessionState.totalSleepMinutes,
            "totalAwakeMinutes": sessionState.totalAwakeMinutes,
            "hasRecentDeepSleep": sessionState.hasRecentDeepSleep,
            "isFinalized": sessionState.isFinalized,
            "sessionStartDate": sessionState.sessionStartDate as Any,
            "latestSegmentEndDate": sessionState.latestSegmentEndDate as Any,
            "lastDeepSleepEndDate": sessionState.lastDeepSleepEndDate as Any,
            "finalizedAt": sessionState.finalizedAt as Any
        ])
    }
    
    private func handleResetSleepSession(result: @escaping FlutterResult) {
        sessionState = .empty
        sessionDetector.clearState()
        print("🛏️ [Humango Health] Sleep session reset")
        result(["status": "reset"])
    }
    
    private func handleConfigureSleepBackgroundDelivery(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let modeStr = args["mode"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing 'mode' argument", details: nil))
            return
        }
        
        guard let mode = SleepBackgroundDeliveryMode(rawValue: modeStr) else {
            result(FlutterError(code: "INVALID_MODE", message: "Mode must be 'api' or 'localStorage'", details: nil))
            return
        }
        
        var apiURL: URL? = nil
        if let urlStr = args["apiURL"] as? String {
            apiURL = URL(string: urlStr)
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        
        deliveryManager.configure(mode: mode, apiURL: apiURL, headers: headers)
        
        if mode == .api && monitorStartDate != nil {
            // Already monitoring: restart to pick up API delivery mode
            if isLiveStreaming {
                stopLiveUpdates()
                startLiveUpdates()
            }
            print("🛏️ [Humango Health] Switched to API delivery mode — live streaming will accumulate + trigger API")
        } else if mode == .api && monitorStartDate == nil {
            // Not monitoring yet: auto-start now that API is configured
            autoStartIfConfigured()
        }
        
        // If switching to localStorage while monitoring is active:
        // restart to pick up the new delivery mode
        if mode == .localStorage && monitorStartDate != nil {
            if isLiveStreaming {
                stopLiveUpdates()
                startLiveUpdates()
            }
            print("🛏️ [Humango Health] Switched to localStorage delivery mode — live streaming will push to EventChannel")
        }
        
        result([
            "status": "configured",
            "mode": mode.rawValue,
            "apiURL": apiURL?.absoluteString as Any,
            "headersCount": headers.count
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
        
        print("🛏️ [Humango Health] Fetched \(samples.count) sleep samples from \(isoFormatter.string(from: queryStartDate)) to \(isoFormatter.string(from: queryEndDate))")
        
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
    
    /// Starts foreground monitoring using HKAnchoredObjectQueryDescriptor.
    /// Samples are accumulated into session state and evaluated.
    /// When the session ends (multi-factor scoring), the finalized data is delivered
    /// via the configured delivery mode (API POST or local storage).
    private func startLiveUpdates() {
        guard !isLiveStreaming else { return }
        guard let startDate = monitorStartDate else { return }
        
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            print("🛏️ [Humango Health] Sleep analysis type not available")
            return
        }
        
        isLiveStreaming = true
        // Open-ended predicate: start at monitorStartDate, no endDate so future samples match
        let livePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: nil,
            options: [.strictStartDate]
        )
        
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
                        
                        // Accumulate all new samples into session state and evaluate.
                        // Delivery (API POST or local storage) is handled by deliveryManager
                        // when the session is finalized.
                        let sampleDicts = update.addedSamples.map { self.convertSampleToDict($0) }
                        if !sampleDicts.isEmpty {
                            print("🛏️ [Humango Health] Foreground update: \(sampleDicts.count) new samples — accumulating into session")
                            self.sessionDetector.updateState(&self.sessionState, withSamples: sampleDicts)
                            self.sessionDetector.saveState(self.sessionState)
                            
                            // Store full snapshot for fetchStoredSleepData / getLocalSleepSessions
                            Task {
                                if let fullData = try? await self.fetchSleepData(startDate: startDate, endDate: Date()) {
                                    self.storeSleepDataToUserDefaults(fullData)
                                }
                            }
                            
                            print("🛏️ [Humango Health] Session state: \(self.sessionState.segmentCount) segments, "
                                  + "\(String(format: "%.0f", self.sessionState.totalSleepMinutes))m sleep, "
                                  + "deepRecent=\(self.sessionState.hasRecentDeepSleep), "
                                  + "freeze=\(self.sessionDetector.isInFreezeWindow())")
                            
                            self.evaluateAndNotifySessionStatus()
                        }
                        
                        for deletedObject in update.deletedObjects {
                            print("🛏️ [Humango Health] Foreground update: sample deleted \(deletedObject.uuid.uuidString)")
                        }
                    }
                } catch {
                    print("🛏️ [Humango Health] Foreground monitoring error: \(error)")
                }
            }
            
            print("🛏️ [Humango Health] Started foreground sleep monitoring (Descriptor, delivery=\(deliveryManager.mode.rawValue))")
        } else {
            print("🛏️ [Humango Health] Foreground monitoring requires iOS 15.0+")
        }
    }
    
    private func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        isLiveStreaming = false
        print("🛏️ [Humango Health] Stopped foreground sleep monitoring")
    }
    
    // MARK: - Background Monitoring
    
    /// Starts background monitoring using HKObserverQuery with freeze-window-aware session detection.
    ///
    /// When sleep data changes:
    /// 1. Fetches new samples and accumulates them into session state
    /// 2. Evaluates whether the sleep session has ended using multi-factor scoring
    /// 3. During freeze window (12 AM - 12 PM): session stays open, data accumulates
    /// 4. After freeze window: session auto-finalizes
    /// 5. Stores accumulated data + session status for Flutter retrieval
    private func startBackgroundMonitoring() {
        guard !isBackgroundMonitoring else { return }
        guard let startDate = monitorStartDate else { return }
        
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            print("🛏️ [Humango Health] Sleep analysis type not available")
            return
        }
        
        isBackgroundMonitoring = true
        
        // Enable background delivery
        Task {
            do {
                try await healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate)
                print("🛏️ [Humango Health] Enabled background delivery for sleep data")
            } catch {
                print("🛏️ [Humango Health] enableBackgroundDelivery failed: \(error)")
            }
        }
        
        // Create observer query
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: nil,
            options: [.strictStartDate]
        )
        
        observerQuery = HKObserverQuery(sampleType: sleepType, predicate: predicate) { [weak self] _, completion, error in
            guard let self = self else { completion(); return }
            defer { completion() }
            
            if let error = error {
                print("🛏️ [Humango Health] Observer query error: \(error)")
                return
            }
            
            print("🛏️ [Humango Health] Background sleep observer fired (freeze window: \(self.sessionDetector.isInFreezeWindow() ? "ACTIVE" : "INACTIVE"))")
            
            // Fetch, accumulate into session state, evaluate, and store
            Task {
                await self.fetchAccumulateAndEvaluate()
            }
        }
        
        if let query = observerQuery {
            healthStore.execute(query)
            print("🛏️ [Humango Health] Started background sleep monitoring with freeze window")
        }
        
        // Start periodic freeze window check timer
        startFreezeCheckTimer()
    }
    
    private func stopBackgroundMonitoring() {
        if let query = observerQuery {
            healthStore.stop(query)
            observerQuery = nil
        }
        
        // Stop freeze check timer
        freezeCheckTimer?.invalidate()
        freezeCheckTimer = nil
        
        // Disable background delivery
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            healthStore.disableBackgroundDelivery(for: sleepType) { success, error in
                if let error = error {
                    print("🛏️ [Humango Health] disableBackgroundDelivery error: \(error)")
                } else {
                    print("🛏️ [Humango Health] disableBackgroundDelivery success: \(success)")
                }
            }
        }
        
        isBackgroundMonitoring = false
        print("🛏️ [Humango Health] Stopped background sleep monitoring")
    }
    
    // MARK: - Freeze Window Timer
    
    /// Starts a periodic timer that checks if the freeze window has expired.
    /// This ensures sessions are finalized even if no new HealthKit data arrives.
    private func startFreezeCheckTimer() {
        freezeCheckTimer?.invalidate()
        
        // Check every 15 minutes
        DispatchQueue.main.async { [weak self] in
            self?.freezeCheckTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.evaluateAndNotifySessionStatus()
            }
        }
        
        print("🛏️ [Humango Health] Started freeze window check timer (every 15 min)")
    }
    
    // MARK: - Freeze-Aware Accumulation & Evaluation
    
    /// Core background logic: fetch new samples, accumulate into session state,
    /// evaluate whether session ended, and store results.
    private func fetchAccumulateAndEvaluate() async {
        guard let startDate = monitorStartDate else { return }
        
        do {
            // Fetch all sleep data from monitoring start to now
            let sleepData = try await fetchSleepData(startDate: startDate, endDate: Date())
            
            // Store the full data snapshot (for fetchStoredSleepData compatibility)
            storeSleepDataToUserDefaults(sleepData)
            
            // Extract samples and update session state
            if let samples = sleepData["samples"] as? [[String: Any]] {
                sessionDetector.updateState(&sessionState, withSamples: samples)
                sessionDetector.saveState(sessionState)
                
                print("🛏️ [Humango Health] Session state: \(sessionState.segmentCount) segments, "
                      + "\(String(format: "%.0f", sessionState.totalSleepMinutes))m sleep, "
                      + "deepRecent=\(sessionState.hasRecentDeepSleep), "
                      + "freeze=\(sessionDetector.isInFreezeWindow())")
            }
            
            // Evaluate session
            evaluateAndNotifySessionStatus()
            
        } catch {
            print("🛏️ [Humango Health] Error in fetchAccumulateAndEvaluate: \(error)")
        }
    }
    
    /// Evaluates the session status and sends a notification to Flutter if ended/expired.
    private func evaluateAndNotifySessionStatus() {
        guard !sessionState.isFinalized else { return }
        guard sessionState.segmentCount > 0 else { return }
        
        let status = sessionDetector.evaluateSession(state: sessionState)
        
        switch status {
        case .active:
            break // Still accumulating
            
        case .ended(let reason):
            sessionDetector.finalizeState(&sessionState, reason: reason)
            notifyFlutterSessionEnded(reason: reason)
            
        case .freezeExpired:
            sessionDetector.finalizeState(&sessionState, reason: "freeze_window_expired")
            notifyFlutterSessionEnded(reason: "freeze_window_expired")
        }
    }
    
    /// Finalizes the sleep session and delivers it via the configured delivery mode (API or local storage).
    private func notifyFlutterSessionEnded(reason: String) {
        print("🛏️ [Humango Health] Sleep session ended (\(reason)) — delivering via \(deliveryManager.mode.rawValue)")
        
        // Deliver via configured mode (API or localStorage)
        Task { [weak self] in
            guard let self = self else { return }
            
            // Fetch the full sleep data for the session
            if let startDate = self.monitorStartDate {
                do {
                    let fullSleepData = try await self.fetchSleepData(startDate: startDate, endDate: Date())
                    // Merge session metadata with full sleep data
                    var deliveryPayload = fullSleepData
                    deliveryPayload["reason"] = reason
                    deliveryPayload["segmentCount"] = self.sessionState.segmentCount
                    deliveryPayload["isFinalized"] = self.sessionState.isFinalized
                    deliveryPayload["finalizedAt"] = self.sessionState.finalizedAt as Any
                    deliveryPayload["sessionStartDate"] = self.sessionState.sessionStartDate as Any
                    deliveryPayload["latestSegmentEndDate"] = self.sessionState.latestSegmentEndDate as Any
                    
                    if let jsonData = try? JSONSerialization.data(withJSONObject: deliveryPayload, options: []),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        let sessionId = self.sessionState.sessionStartDate ?? self.isoFormatter.string(from: Date())
                        
                        print("🛏️ [Humango Health] ── SESSION DATA RECORDED ──────────────")
                        print("🛏️ [Humango Health] Session ID: \(sessionId)")
                        print("🛏️ [Humango Health] Reason: \(reason)")
                        print("🛏️ [Humango Health] Segments: \(self.sessionState.segmentCount)")
                        print("🛏️ [Humango Health] Total sleep: \(String(format: "%.1f", self.sessionState.totalSleepMinutes))m")
                        print("🛏️ [Humango Health] Total awake: \(String(format: "%.1f", self.sessionState.totalAwakeMinutes))m")
                        print("🛏️ [Humango Health] Session start: \(self.sessionState.sessionStartDate ?? "nil")")
                        print("🛏️ [Humango Health] Session end: \(self.sessionState.latestSegmentEndDate ?? "nil")")
                        print("🛏️ [Humango Health] Finalized at: \(self.sessionState.finalizedAt ?? "nil")")
                        print("🛏️ [Humango Health] Delivery mode: \(self.deliveryManager.mode.rawValue)")
                        print("🛏️ [Humango Health] JSON payload size: \(jsonData.count) bytes")
                        if let sampleCount = deliveryPayload["sampleCount"] as? Int {
                            print("🛏️ [Humango Health] Samples in payload: \(sampleCount)")
                        }
                        print("🛏️ [Humango Health] ─────────────────────────────────────")
                        
                        await self.deliveryManager.deliverSleepSession(jsonString, sessionId: sessionId)
                    }
                } catch {
                    print("🛏️ [Humango Health] Error fetching full sleep data for delivery: \(error)")
                }
            }
        }
        
    }
    
    // MARK: - UserDefaults Storage
    
    /// Fetches sleep data and stores it in UserDefaults for later retrieval.
    /// Also accumulates into session state for freeze-window-aware detection.
    private func fetchAndStoreSleepData() async {
        await fetchAccumulateAndEvaluate()
    }
    
    private func storeSleepDataToUserDefaults(_ sleepData: [String: Any]) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: sleepData, options: [])
            UserDefaults.standard.set(jsonData, forKey: SleepDataKeys.storedSleepData)
            UserDefaults.standard.set(Date(), forKey: SleepDataKeys.lastFetchDate)
            print("🛏️ [Humango Health] Sleep data saved to UserDefaults")
        } catch {
            print("🛏️ [Humango Health] Error serializing sleep data: \(error)")
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
                // Add storage metadata
                if let storedDate = UserDefaults.standard.object(forKey: SleepDataKeys.lastFetchDate) as? Date {
                    sleepData["storedAt"] = isoFormatter.string(from: storedDate)
                }
                sleepData["hasData"] = true
                return sleepData
            }
        } catch {
            print("🛏️ [Humango Health] Error deserializing stored sleep data: \(error)")
        }
        
        return ["samples": [], "sampleCount": 0, "hasData": false]
    }
    
    private func clearStoredSleepData() {
        UserDefaults.standard.removeObject(forKey: SleepDataKeys.storedSleepData)
        UserDefaults.standard.removeObject(forKey: SleepDataKeys.lastFetchDate)
        print("🛏️ [Humango Health] Cleared stored sleep data")
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
