//
//  SleepDataManager.swift
//  humango_health
//
//  Fetches and monitors sleep data from Apple HealthKit
//  Supports: one-shot fetch, live streaming (foreground), background observation
//  Uses native iOS lifecycle detection via AppLifecycleManager for automatic mode switching
//

import Flutter
import HealthKit
import Foundation

// MARK: - UserDefaults Keys for Sleep Data

private struct SleepDataKeys {
    static let storedSleepData = "com.humango.health.storedSleepData"
    static let lastFetchDate = "com.humango.health.lastSleepFetchDate"
}

// MARK: - SleepDataManager

@available(iOS 14.0, *)
public class SleepDataManager: NSObject, FlutterStreamHandler, AppLifecycleObserver {
    static let shared = SleepDataManager()
    
    private let healthStore = HKHealthStore()
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    // Event channel sink for streaming sleep updates to Flutter
    private var eventSink: FlutterEventSink?
    
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
        // Register with AppLifecycleManager for automatic foreground/background switching
        AppLifecycleManager.shared.addObserver(self)
        print("🛏️ [Humango Health] SleepDataManager initialized with native lifecycle observer")
    }
    
    deinit {
        AppLifecycleManager.shared.removeObserver(self)
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
        print("🛏️ [Humango Health] Switched to foreground mode (live streaming) via native lifecycle")
    }
    
    private func switchToBackgroundMode() {
        guard monitorStartDate != nil else { return }
        
        stopLiveUpdates()
        startBackgroundMonitoring()
        print("🛏️ [Humango Health] Switched to background mode (observer query) via native lifecycle")
    }
    
    // MARK: - FlutterStreamHandler
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        print("🛏️ [Humango Health] Sleep EventChannel: onListen")
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        print("🛏️ [Humango Health] Sleep EventChannel: onCancel")
        return nil
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
        
        // Start appropriate mode based on current app state (from native lifecycle manager)
        if AppLifecycleManager.shared.isInForeground {
            startLiveUpdates()
        } else {
            startBackgroundMonitoring()
        }
        
        print("🛏️ [Humango Health] Started sleep monitoring from \(isoFormatter.string(from: startDate))")
        result(["status": "started", "startDate": isoFormatter.string(from: startDate)])
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
    
    // MARK: - Live Streaming (Foreground)
    
    /// Starts live streaming of sleep data changes using HKAnchoredObjectQueryDescriptor.
    /// Each new/updated sleep sample is pushed to Flutter via EventChannel.
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
                        
                        for sample in update.addedSamples {
                            let sampleDict = self.convertSampleToDict(sample)
                            print("🛏️ [Humango Health] Live sleep update: \(sample.uuid.uuidString)")
                            
                            // Push to Flutter via EventChannel
                            DispatchQueue.main.async {
                                self.eventSink?([
                                    "type": "sleepSample",
                                    "sample": sampleDict
                                ])
                            }
                        }
                        
                        // Handle deleted samples
                        for deletedObject in update.deletedObjects {
                            DispatchQueue.main.async {
                                self.eventSink?([
                                    "type": "sleepSampleDeleted",
                                    "uuid": deletedObject.uuid.uuidString
                                ])
                            }
                        }
                    }
                } catch {
                    print("🛏️ [Humango Health] Live updates error: \(error)")
                    DispatchQueue.main.async {
                        self.eventSink?(FlutterError(
                            code: "LIVE_UPDATE_ERROR",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }
            
            print("🛏️ [Humango Health] Started live sleep streaming")
        } else {
            print("🛏️ [Humango Health] Live streaming requires iOS 15.0+")
        }
    }
    
    private func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        isLiveStreaming = false
        print("🛏️ [Humango Health] Stopped live sleep streaming")
    }
    
    // MARK: - Background Monitoring
    
    /// Starts background monitoring using HKObserverQuery.
    /// When sleep data changes, fetches new data and stores in UserDefaults.
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
            
            print("🛏️ [Humango Health] Background sleep observer fired")
            
            // Fetch new data and store in UserDefaults
            Task {
                await self.fetchAndStoreSleepData()
            }
        }
        
        if let query = observerQuery {
            healthStore.execute(query)
            print("🛏️ [Humango Health] Started background sleep monitoring")
        }
    }
    
    private func stopBackgroundMonitoring() {
        if let query = observerQuery {
            healthStore.stop(query)
            observerQuery = nil
        }
        
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
    
    // MARK: - UserDefaults Storage
    
    /// Fetches sleep data and stores it in UserDefaults for later retrieval
    private func fetchAndStoreSleepData() async {
        guard let startDate = monitorStartDate else { return }
        
        do {
            let sleepData = try await fetchSleepData(startDate: startDate, endDate: Date())
            storeSleepDataToUserDefaults(sleepData)
            print("🛏️ [Humango Health] Stored \(sleepData["sampleCount"] ?? 0) sleep samples to UserDefaults")
        } catch {
            print("🛏️ [Humango Health] Error fetching sleep data for storage: \(error)")
        }
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
