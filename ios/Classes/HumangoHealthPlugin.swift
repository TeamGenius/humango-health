import Flutter
import UIKit

public class HumangoHealthPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let permissionMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/permissions", binaryMessenger: registrar.messenger())
    let permissionEventChannel = FlutterEventChannel(name: "com.humango.workouts/permissions/stream", binaryMessenger: registrar.messenger())
    
    let instance = HumangoHealthPlugin()
    registrar.addMethodCallDelegate(instance, channel: permissionMethodChannel)
    permissionEventChannel.setStreamHandler(PermissionStreamHandler())
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "verify" {
        guard let args = call.arguments as? [String: Any],
              let readTypes = args["readTypes"] as? [String],
              let writeTypes = args["writeTypes"] as? [String] else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for verify", details: nil))
            return
        }
        
        let status = PermissionManager.shared.verifyPermissions(readTypes: readTypes, writeTypes: writeTypes)
        result(status)
        
    } else if call.method == "request" {
        guard let args = call.arguments as? [String: Any],
              let readTypes = args["readTypes"] as? [String],
              let writeTypes = args["writeTypes"] as? [String] else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for request", details: nil))
            return
        }
        
        result(nil)
        PermissionManager.shared.requestPermissions(readTypes: readTypes, writeTypes: writeTypes) { _ in }
        
    } else {
        result(FlutterMethodNotImplemented)
    }
  }
}
