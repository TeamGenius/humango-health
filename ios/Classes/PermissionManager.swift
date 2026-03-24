import Flutter
import HealthKit
import UIKit

public class PermissionManager {
    public static let shared = PermissionManager()
    var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    
    // MARK: - EventChannel sink (holds the live stream connection to Flutter)
    var healthKitEventSink: FlutterEventSink?
    
    /// Guards against applicationDidBecomeActive emitting stale snapshot data
    /// during a fresh requestAuthorization flow.
    var isFreshAuthInProgress = false
    
    // MARK: - Centralized event emission with diff logging
    
    /// Emits a status map to the EventChannel and logs any changes from the previous emission.
    func emitPermissionStatus(_ status: [String: Any]) {
        let previous = loadAuthSnapshot()
        logPermissionChanges(previous: previous, current: status)
        DispatchQueue.main.async {
            self.healthKitEventSink?(status)
        }
    }
    
    private func logPermissionChanges(previous: [String: String], current: [String: Any]) {
        let currentStrings = current.compactMapValues { $0 as? String }
        
        if previous.isEmpty {
            print("[PermissionManager] 🟢 Initial permission status:")
            for (key, value) in currentStrings.sorted(by: { $0.key < $1.key }) {
                print("  \(key): \(value)")
            }
            return
        }
        
        var changes: [(key: String, from: String, to: String)] = []
        let allKeys = Set(previous.keys).union(Set(currentStrings.keys))
        
        for key in allKeys.sorted() {
            let old = previous[key] ?? "(missing)"
            let new = currentStrings[key] ?? "(missing)"
            if old != new {
                changes.append((key: key, from: old, to: new))
            }
        }
        
        if changes.isEmpty {
            print("[PermissionManager] ℹ️ No permission changes detected.")
        } else {
            print("[PermissionManager] ⚠️ Permission changes detected (\(changes.count)):")
            for change in changes {
                print("  \(change.key): \(change.from) → \(change.to)")
            }
        }
    }
    
    // MARK: - Cached previous authorization snapshot (used to detect regressions)
    private let cacheKey = "com.humango.health.lastKnownPermissions"
    
    // Comprehensive quantity identifiers for all workout and health data types
    // Hard-coded authorization regardless of user workout preferences
    private let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .stepCount,
        .distanceCycling,
        .swimmingStrokeCount,
        .distanceSwimming,
        .vo2Max,
        .distanceWalkingRunning,
        .activeEnergyBurned,
        .bodyMass,
        .height,
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .bodyMassIndex,
        .bodyFatPercentage,
        .runningGroundContactTime,
        .runningPower,
        .runningSpeed,
        .runningStrideLength,
        .runningVerticalOscillation,
        .cyclingCadence,
        .cyclingPower
    ]

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        if let st = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(st) }
        for id in quantityIdentifiers {
            if let q = HKObjectType.quantityType(forIdentifier: id) { types.insert(q) }
        }
        return types
    }

    private var writeTypes: Set<HKSampleType> {
        return [HKObjectType.workoutType()]
    }
    
    // MARK: - Type-to-key mapping (safe, no force unwraps)
    
    private var typesToCheck: [(key: String, type: HKObjectType)] {
        var items: [(key: String, type: HKObjectType)] = []
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)           { items.append(("sleepStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { items.append(("hrvStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate)         { items.append(("restingHeartRateStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .heartRate)                { items.append(("heartRateStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .bodyMass)                 { items.append(("bodyMassStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .height)                   { items.append(("heightStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)        { items.append(("bodyFatStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)       { items.append(("activeEnergyStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)   { items.append(("distanceStatus", t)) }
        if let t = HKObjectType.quantityType(forIdentifier: .stepCount)                { items.append(("stepsStatus", t)) }
        return items
    }
    
    // MARK: - Lookback window per type (body metrics are recorded infrequently)
    
    private func lookbackDays(for key: String) -> Int {
        switch key {
        case "bodyMassStatus", "heightStatus", "bodyFatStatus":
            return 30
        case "hrvStatus", "restingHeartRateStatus":
            return 7
        case "sleepStatus":
            return 3
        default:
            return 1
        }
    }
    
    // MARK: - Cumulative vs discrete types
    // Cumulative types (steps, energy, distance) use .cumulativeSum
    // Discrete types (heart rate, HRV, body mass, etc.) use .discreteAverage
    
    private let cumulativeIdentifiers: Set<HKQuantityTypeIdentifier> = [
        .activeEnergyBurned,
        .stepCount,
        .distanceWalkingRunning
    ]
    
    private func statisticsOptions(for quantityType: HKQuantityType) -> HKStatisticsOptions {
        if let id = HKQuantityTypeIdentifier(rawValue: quantityType.identifier) as HKQuantityTypeIdentifier?,
           cumulativeIdentifiers.contains(id) {
            return .cumulativeSum
        }
        return .discreteAverage
    }

    /// HealthKit "no samples in range" is not a read denial, but the NSError is sometimes wrapped
    /// so `domain == com.apple.healthkit && code == 5` fails while the message still says
    /// "No data available for the specified predicate."
    /// True for HKErrorNoData (empty query result). The old check used code `5`, but that is
    /// `HKError.Code.authorizationNotDetermined`, not "no data".
    private func isHealthKitNoDataError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let err = current {
            if err.domain == HKError.errorDomain,
               err.code == HKError.Code.errorNoData.rawValue {
                return true
            }
            current = err.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    
    // MARK: - Public API
    
    public func requestAuthorization(result: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable() else {
            result(FlutterError(code: "NOT_AVAILABLE", message: "HealthKit is not available on this device", details: nil))
            return
        }

        // Clear snapshot BEFORE showing the auth sheet so that if
        // applicationDidBecomeActive fires first (race), it uses an empty
        // snapshot and won't falsely mark no-data types as "denied".
        self.isFreshAuthInProgress = true
        self.clearAuthSnapshot()
        
        healthStore.requestAuthorization(toShare: writeTypes, read: readTypes) { [weak self] success, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    print("[PermissionManager] ❌ Authorization error: \(error.localizedDescription)")
                    self.isFreshAuthInProgress = false
                    let flutterError = FlutterError(code: "AUTH_ERROR", message: error.localizedDescription, details: nil)
                    self.healthKitEventSink?(flutterError)
                    result(flutterError)
                    return
                }

                print("[PermissionManager] ✅ Authorization sheet dismissed — checking status")
                DispatchQueue.global().async {
                    let status = self.buildDetailedAuthorizationStatus(persistSnapshot: true)
                    self.emitPermissionStatus(status)
                    self.isFreshAuthInProgress = false
                    DispatchQueue.main.async {
                        result(true)
                    }
                }
            }
        }
    }
    
    public func verifyAuthorization(result: @escaping FlutterResult) {
        print("[PermissionManager] 🔍 verifyAuthorization called")
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let detailedStatus = self.buildDetailedAuthorizationStatus(persistSnapshot: true)
            self.emitPermissionStatus(detailedStatus)
            DispatchQueue.main.async {
                result(detailedStatus)
            }
        }
    }

    public func buildDetailedAuthorizationStatus(persistSnapshot: Bool = true) -> [String: Any] {
        let workout       = HKObjectType.workoutType()
        let workoutStatus = writeAuthStatus(for: workout)

        let readStatuses = readAuthStatuses()

        let allGranted = workoutStatus == "authorized"
            && readStatuses.values.allSatisfy { $0 == "authorized" }

        var map: [String: Any] = [
            "isAuthorized":         allGranted,
            "workoutStatus":        workoutStatus,
        ]
        readStatuses.forEach { map[$0.key] = $0.value }
        
        if persistSnapshot {
            self.persistAuthSnapshot(map)
        }
        
        return map
    }
    
    // MARK: - Conservative merge (picks the more restrictive status for each key)
    
    private func mergeConservative(first: [String: Any], second: [String: Any]) -> [String: Any] {
        let statusPriority: [String: Int] = [
            "denied": 0,
            "noData": 1,
            "unknown": 2,
            "authorized": 3
        ]
        
        var merged: [String: Any] = [:]
        // Use all keys from both dictionaries
        let allKeys = Set(first.keys).union(Set(second.keys))
        
        for key in allKeys {
            if key == "isAuthorized" {
                // Recalculate at the end
                continue
            }
            
            let val1 = first[key]
            let val2 = second[key]
            
            if let s1 = val1 as? String, let s2 = val2 as? String {
                let p1 = statusPriority[s1] ?? 3
                let p2 = statusPriority[s2] ?? 3
                // Pick the one with lower priority (more restrictive)
                merged[key] = p1 <= p2 ? s1 : s2
            } else {
                // Use whichever is available
                merged[key] = val2 ?? val1
            }
        }
        
        // Recalculate isAuthorized based on merged values
        let workoutOk = (merged["workoutStatus"] as? String) == "authorized"
        let allReadOk = merged
            .filter { $0.key != "workoutStatus" }
            .compactMap { $0.value as? String }
            .allSatisfy { $0 == "authorized" }
        merged["isAuthorized"] = workoutOk && allReadOk
        
        return merged
    }

    private func writeAuthStatus(for type: HKObjectType) -> String {
        switch healthStore.authorizationStatus(for: type) {
        case .sharingAuthorized: return "authorized"
        case .sharingDenied:     return "denied"
        case .notDetermined:     return "unknown"
        @unknown default:        return "unknown"
        }
    }

    // MARK: - Read permission checking (two-pass: request-status + data probe)

    private func readAuthStatuses() -> [String: String] {
        let items = typesToCheck
        var result = [String: String]()
        let lock = NSLock()
        
        // ──────────────────────────────────────────────────────────────────────
        // Pass 1: getRequestStatusForAuthorization
        //   .shouldRequest  → user was NEVER prompted → "unknown"
        //   .unnecessary    → user WAS prompted → need Pass 2 to disambiguate
        // ──────────────────────────────────────────────────────────────────────
        let semaphore = DispatchSemaphore(value: 0)
        var pendingReqChecks = items.count
        var requestStatuses: [String: HKAuthorizationRequestStatus] = [:]
        
        for item in items {
            let readSet: Set<HKObjectType> = [item.type]
            healthStore.getRequestStatusForAuthorization(toShare: Set<HKSampleType>(), read: readSet) { status, error in
                lock.lock()
                requestStatuses[item.key] = status
                lock.unlock()
                
                pendingReqChecks -= 1
                if pendingReqChecks == 0 {
                    semaphore.signal()
                }
            }
        }
        semaphore.wait()

        // ──────────────────────────────────────────────────────────────────────
        // Pass 2: For each .unnecessary type, probe for data presence.
        //
        //   Apple's privacy model: denied read types return empty results
        //   (not errors). So:
        //     - data found        → definitely authorized
        //     - no data / error   → could be denied OR no data recorded
        //
        //   We use HKStatisticsQuery for quantity types and HKSampleQuery for
        //   category types. Previous-snapshot comparison helps detect cases
        //   where data was previously available but is no longer (= revoked).
        // ──────────────────────────────────────────────────────────────────────
        let queryGroup = DispatchGroup()
        let previousSnapshot = loadAuthSnapshot()
        print("[PermissionManager] 📸 Previous snapshot: \(previousSnapshot)")
        
        for item in items {
            let reqStat = requestStatuses[item.key] ?? .unknown
            print("[PermissionManager] 🔎 \(item.key): requestStatus=\(reqStat.rawValue)")
            
            if reqStat == .shouldRequest {
                lock.lock()
                result[item.key] = "unknown"
                lock.unlock()
                continue
            }
            
            // For quantity types, use HKStatisticsQuery
            if let quantityType = item.type as? HKQuantityType {
                queryGroup.enter()
                let days = lookbackDays(for: item.key)
                let endDate = Date()
                guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate) else {
                    lock.lock()
                    result[item.key] = "noData"
                    lock.unlock()
                    queryGroup.leave()
                    continue
                }
                let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
                
                let options = statisticsOptions(for: quantityType)
                let isCumulative = options == .cumulativeSum
                
                let statsQuery = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: options) { (_, statistics, error) in
                    lock.lock()
                    defer {
                        lock.unlock()
                        queryGroup.leave()
                    }
                    
                    if let error = error {
                        if self.isHealthKitNoDataError(error) {
                            let prev = previousSnapshot[item.key] ?? "(none)"
                            print("[PermissionManager] ⚪ \(item.key): HK 'no data' error, previousSnapshot=\(prev)")
                            if previousSnapshot[item.key] == "authorized" {
                                result[item.key] = "denied"
                            } else {
                                result[item.key] = "noData"
                            }
                        } else {
                            print("[PermissionManager] ❌ \(item.key): query ERROR → \(error.localizedDescription)")
                            result[item.key] = "denied"
                        }
                    } else if let stats = statistics,
                              (isCumulative ? stats.sumQuantity() != nil : stats.averageQuantity() != nil) {
                        print("[PermissionManager] ✅ \(item.key): data found → authorized")
                        result[item.key] = "authorized"
                    } else {
                        let prev = previousSnapshot[item.key] ?? "(none)"
                        print("[PermissionManager] ⚪ \(item.key): no data, previousSnapshot=\(prev)")
                        if previousSnapshot[item.key] == "authorized" {
                            result[item.key] = "denied"
                        } else {
                            result[item.key] = "noData"
                        }
                    }
                }
                
                healthStore.execute(statsQuery)
                continue
            }
            
            // For category types (e.g. sleep), use HKSampleQuery
            guard let sampleType = item.type as? HKSampleType else {
                lock.lock()
                result[item.key] = "noData"
                lock.unlock()
                continue
            }
            
            queryGroup.enter()
            let days = lookbackDays(for: item.key)
            let endDate = Date()
            let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate)
            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
            
            let query = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: 1, sortDescriptors: nil) { (_, samples, error) in
                lock.lock()
                defer {
                    lock.unlock()
                    queryGroup.leave()
                }
                
                if let error = error {
                    if self.isHealthKitNoDataError(error) {
                        let prev = previousSnapshot[item.key] ?? "(none)"
                        print("[PermissionManager] ⚪ \(item.key): sample 'no data' error, previousSnapshot=\(prev)")
                        if previousSnapshot[item.key] == "authorized" {
                            result[item.key] = "denied"
                        } else {
                            result[item.key] = "noData"
                        }
                    } else {
                        print("[PermissionManager] ❌ \(item.key): sample query ERROR → \(error.localizedDescription)")
                        result[item.key] = "denied"
                    }
                } else if let samples = samples, !samples.isEmpty {
                    print("[PermissionManager] ✅ \(item.key): sample data found → authorized")
                    result[item.key] = "authorized"
                } else {
                    let prev = previousSnapshot[item.key] ?? "(none)"
                    print("[PermissionManager] ⚪ \(item.key): no sample data, previousSnapshot=\(prev)")
                    if previousSnapshot[item.key] == "authorized" {
                        result[item.key] = "denied"
                    } else {
                        result[item.key] = "noData"
                    }
                }
            }
            
            healthStore.execute(query)
        }

        queryGroup.wait()
        return result
    }
    
    // MARK: - Snapshot persistence (UserDefaults)
    
    private func persistAuthSnapshot(_ map: [String: Any]) {
        var snapshot: [String: String] = [:]
        for (key, value) in map {
            if let strValue = value as? String {
                snapshot[key] = strValue
            }
        }
        UserDefaults.standard.set(snapshot, forKey: cacheKey)
    }
    
    private func loadAuthSnapshot() -> [String: String] {
        return UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
    }
    
    private func clearAuthSnapshot() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }
}

// MARK: - PermissionStreamHandler

public class PermissionStreamHandler: NSObject, FlutterStreamHandler {
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        PermissionManager.shared.healthKitEventSink = events
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        NotificationCenter.default.removeObserver(self)
        PermissionManager.shared.healthKitEventSink = nil
        return nil
    }
    
    @objc private func applicationDidBecomeActive() {
        // Delay to let HealthKit settle after returning from Settings
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            // Skip if requestAuthorization is in flight — it will emit its own
            // results with a cleared snapshot. Running here would use a stale
            // snapshot and could falsely mark no-data types as "denied".
            guard !PermissionManager.shared.isFreshAuthInProgress else {
                print("[PermissionStreamHandler] ⏭️ Skipping — fresh auth in progress")
                return
            }
            print("[PermissionStreamHandler] 🔄 App became active — re-checking permissions")
            let detailedStatus = PermissionManager.shared.buildDetailedAuthorizationStatus(persistSnapshot: true)
            PermissionManager.shared.emitPermissionStatus(detailedStatus)
        }
    }
}
