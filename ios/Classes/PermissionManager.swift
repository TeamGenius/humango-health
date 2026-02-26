import Flutter
import HealthKit
import UIKit

public class PermissionManager {
    public static let shared = PermissionManager()
    let healthStore = HKHealthStore()
    
    // MARK: - EventChannel sink (holds the live stream connection to Flutter)
    var healthKitEventSink: FlutterEventSink?
    
    private let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .bodyMass,
        .height,
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .bodyFatPercentage,
        .activeEnergyBurned,
        .stepCount,
        .distanceWalkingRunning
    ]

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        types.insert(HKObjectType.workoutType())
        if let st = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(st) }
        for id in quantityIdentifiers {
            if let q = HKObjectType.quantityType(forIdentifier: id) { types.insert(q) }
        }
        return types
    }

    private var writeTypes: Set<HKSampleType> {
        return [HKObjectType.workoutType()]
    }
    
    public func requestAuthorization(result: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable() else {
            result(FlutterError(code: "NOT_AVAILABLE", message: "HealthKit is not available on this device", details: nil))
            return
        }

        healthStore.requestAuthorization(toShare: writeTypes, read: readTypes) { [weak self] success, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    let flutterError = FlutterError(code: "AUTH_ERROR", message: error.localizedDescription, details: nil)
                    self.healthKitEventSink?(flutterError)
                    result(flutterError)
                    return
                }

                // Run status checking on background thread since getRequestStatus uses semaphore
                DispatchQueue.global().async {
                    let detailedStatus = self.buildDetailedAuthorizationStatus()
                    DispatchQueue.main.async {
                        self.healthKitEventSink?(detailedStatus)
                        result(true)
                    }
                }
            }
        }
    }
    
    public func verifyAuthorization(result: @escaping FlutterResult) {
        // Run on background thread then return to main to avoid blocking Flutter UI with semaphores
        DispatchQueue.global().async {
            let detailedStatus = self.buildDetailedAuthorizationStatus()
            DispatchQueue.main.async {
                result(detailedStatus)
            }
        }
    }

    public func buildDetailedAuthorizationStatus() -> [String: Any] {
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
        return map
    }

    private func writeAuthStatus(for type: HKObjectType) -> String {
        switch healthStore.authorizationStatus(for: type) {
        case .sharingAuthorized: return "authorized"
        case .sharingDenied:     return "denied"
        case .notDetermined:     return "notDetermined"
        @unknown default:        return "unknown"
        }
    }

    private func readAuthStatuses() -> [String: String] {
        let typesToCheck: [(key: String, type: HKObjectType)] = [
            ("sleepStatus",           HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!),
            ("hrvStatus",             HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!),
            ("restingHeartRateStatus",HKObjectType.quantityType(forIdentifier: .restingHeartRate)!),
            ("bodyMassStatus",        HKObjectType.quantityType(forIdentifier: .bodyMass)!),
            ("heightStatus",          HKObjectType.quantityType(forIdentifier: .height)!),
            ("bodyFatStatus",         HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)!),
            ("activeEnergyStatus",    HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!),
            ("distanceStatus",        HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!),
            ("stepsStatus",           HKObjectType.quantityType(forIdentifier: .stepCount)!),
        ]

        var result = [String: String]()
        let semaphore = DispatchSemaphore(value: 0)
        var pending = typesToCheck.count

        for item in typesToCheck {
            let shareSet   = Set<HKSampleType>()
            let readSet: Set<HKObjectType> = [item.type]

            healthStore.getRequestStatusForAuthorization(toShare: shareSet, read: readSet) { status, _ in
                switch status {
                case .unnecessary:
                    result[item.key] = "authorized"
                case .shouldRequest:
                    result[item.key] = "notDetermined"
                case .unknown:
                    result[item.key] = "unknown"
                @unknown default:
                    result[item.key] = "unknown"
                }
                pending -= 1
                if pending == 0 { semaphore.signal() }
            }
        }

        semaphore.wait()
        return result
    }
}

public class PermissionStreamHandler: NSObject, FlutterStreamHandler {
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        PermissionManager.shared.healthKitEventSink = events
        
        // Listen for app coming to foreground to re-emit status
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
        DispatchQueue.global().async {
            let detailedStatus = PermissionManager.shared.buildDetailedAuthorizationStatus()
            DispatchQueue.main.async {
                PermissionManager.shared.healthKitEventSink?(detailedStatus)
            }
        }
    }
}
