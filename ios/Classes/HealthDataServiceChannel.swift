import Flutter
import HealthKit

class HealthDataServiceChannel: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
            
        case "readHealthData":
            guard let args = call.arguments as? [String: Any],
                  let typeStr = args["type"] as? String,
                  let startString = args["startDate"] as? String,
                  let endString = args["endDate"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing required read arguments", details: nil))
                return
            }
            
            guard let type = HKSampleType.fromIdentifier(typeStr) else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid type identifier", details: nil))
                return
            }
            
            guard let startDate = DateUtils.parseDate(from: startString),
                  let endDate = DateUtils.parseDate(from: endString) else {
                result(FlutterError(code: "INVALID_DATE", message: "Invalid date format", details: nil))
                return
            }
            
            let limit = args["limit"] as? Int
            
            HealthDataFetcher.shared.fetchHealthData(type: type, startDate: startDate, endDate: endDate, limit: limit) { samples in
                result(samples)
            }
            
        case "startMonitoring":
            guard let args = call.arguments as? [String: Any],
                  let typeStr = args["type"] as? String,
                  let type = HKSampleType.fromIdentifier(typeStr) else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing type string", details: nil))
                return
            }
            
            let startDateStr = args["startDate"] as? String
            
            var startDate: Date? = nil
            if let str = startDateStr {
                startDate = DateUtils.parseDate(from: str)
            }
            
            HealthDataService.shared.startMonitoring(for: type, startDate: startDate)
            result(true)
            
        case "stopMonitoring":
            guard let args = call.arguments as? [String: Any],
                  let typeStr = args["type"] as? String,
                  let type = HKSampleType.fromIdentifier(typeStr) else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing type", details: nil))
                return
            }
            HealthDataService.shared.stopMonitoring(for: type)
            result(true)
            
        case "getLocalHealthData":
            Task {
                let samples = await HealthDataStore.shared.retrieveAndClearSamples()
                DispatchQueue.main.async {
                    result(samples)
                }
            }
            
        case "enterForeground":
            HealthDataService.shared.enterForegroundMode()
            result(nil)
            
        case "enterBackground":
            HealthDataService.shared.enterBackgroundMode()
            result(nil)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - FlutterStreamHandler
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        HealthDataService.shared.setEventSink(events)
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        HealthDataService.shared.setEventSink(nil)
        return nil
    }
}
