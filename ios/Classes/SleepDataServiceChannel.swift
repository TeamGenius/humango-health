import HealthKit
import Flutter

class SleepDataServiceChannel: NSObject, FlutterPlugin {
    
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.humango.workouts/sleep", binaryMessenger: registrar.messenger())
        let instance = SleepDataServiceChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "readSleepData":
            guard let args = call.arguments as? [String: Any],
                  let pastDays = args["pastDays"] as? Int else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing pastDays argument", details: nil))
                return
            }
            
            SleepDataFetcher.shared.fetchSleepData(pastDays: pastDays) { sleepSessions in
                result(sleepSessions)
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
