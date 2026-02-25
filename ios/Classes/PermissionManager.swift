import Flutter
import HealthKit
import UIKit

public class PermissionManager {
    public static let shared = PermissionManager()
    let healthStore = HKHealthStore()
    
    public func verifyPermissions(readTypes: [String], writeTypes: [String]) -> [String: Any] {
        var readStatuses: [String: String] = [:]
        var writeStatuses: [String: String] = [:]
        
        guard HKHealthStore.isHealthDataAvailable() else {
            return [
                "error": "HealthKit not available on this device",
                "readStatuses": readStatuses,
                "writeStatuses": writeStatuses
            ]
        }
        
        for identifier in readTypes {
            guard let type = createObjectType(for: identifier) else { continue }
            let status = healthStore.authorizationStatus(for: type)
            readStatuses[identifier] = statusString(from: status)
        }
        
        for identifier in writeTypes {
            guard let type = createObjectType(for: identifier) else { continue }
            let status = healthStore.authorizationStatus(for: type)
            writeStatuses[identifier] = statusString(from: status)
        }
        
        return [
            "readStatuses": readStatuses,
            "writeStatuses": writeStatuses
        ]
    }
    
    public func requestPermissions(readTypes: [String], writeTypes: [String], completion: @escaping (Result<Void, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(NSError(domain: "HumangoHealth", code: 1, userInfo: [NSLocalizedDescriptionKey: "HealthKit not available"])))
            return
        }
        
        var readSet = Set<HKObjectType>()
        var writeSet = Set<HKSampleType>()
        
        for identifier in readTypes {
            if let type = createObjectType(for: identifier) {
                readSet.insert(type)
            }
        }
        
        for identifier in writeTypes {
            if let type = createSampleType(for: identifier) {
                writeSet.insert(type)
            }
        }
        
        healthStore.requestAuthorization(toShare: writeSet, read: readSet) { success, error in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
    
    private func createObjectType(for identifier: String) -> HKObjectType? {
        if identifier == "HKWorkoutType" {
            return HKObjectType.workoutType()
        }
        if identifier.hasPrefix("HKCategoryTypeIdentifier") {
            return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
        }
        if identifier.hasPrefix("HKQuantityTypeIdentifier") {
            return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
        }
        return nil
    }
    
    private func createSampleType(for identifier: String) -> HKSampleType? {
        return createObjectType(for: identifier) as? HKSampleType
    }
    
    private func statusString(from status: HKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .sharingDenied: return "denied"
        case .sharingAuthorized: return "authorized"
        @unknown default: return "notDetermined"
        }
    }
}

public class PermissionStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var lastArgs: [String: Any]?
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        self.lastArgs = arguments as? [String: Any]
        
        // Emit initial state
        emitCurrentState()
        
        // Listen for app coming to foreground
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
        self.eventSink = nil
        self.lastArgs = nil
        return nil
    }
    
    @objc private func applicationDidBecomeActive() {
        emitCurrentState()
    }
    
    private func emitCurrentState() {
        guard let sink = self.eventSink, let args = self.lastArgs else { return }
        
        let readTypes = args["readTypes"] as? [String] ?? []
        let writeTypes = args["writeTypes"] as? [String] ?? []
        
        let result = PermissionManager.shared.verifyPermissions(readTypes: readTypes, writeTypes: writeTypes)
        sink(result)
    }
}
