import Flutter
import UIKit

public class HumangoHealthPlugin: NSObject, FlutterPlugin {
  private let healthDataChannel = HealthDataServiceChannel()
  private let sleepDataChannel = SleepDataServiceChannel()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let permissionMethodChannel = FlutterMethodChannel(name: "healthkit/method", binaryMessenger: registrar.messenger())
    let permissionEventChannel = FlutterEventChannel(name: "healthkit/event", binaryMessenger: registrar.messenger())
    
    // Phase 5: Read Health Data Subsystem
    let healthMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/health", binaryMessenger: registrar.messenger())
    let healthEventChannel = FlutterEventChannel(name: "com.humango.workouts/health/stream", binaryMessenger: registrar.messenger())
    
    // Phase 6: Sleep Data Management
    let sleepMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/sleep", binaryMessenger: registrar.messenger())
    
    // Phase 3: Workout Scheduling
    let workoutPlanMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/workoutplan", binaryMessenger: registrar.messenger())
    
    let instance = HumangoHealthPlugin()
    
    registrar.addMethodCallDelegate(instance, channel: permissionMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: healthMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: sleepMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutPlanMethodChannel)
    
    permissionEventChannel.setStreamHandler(PermissionStreamHandler())
    healthEventChannel.setStreamHandler(instance.healthDataChannel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "verifyAuthorization" {
          PermissionManager.shared.verifyAuthorization(result: result)
      } else if call.method == "requestAuthorization" {
          PermissionManager.shared.requestAuthorization(result: result)
      } else if ["readHealthData", "startMonitoring", "stopMonitoring", "getLocalHealthData", "enterForeground", "enterBackground"].contains(call.method) {
          healthDataChannel.handle(call, result: result)
      } else if call.method == "readSleepData" {
          sleepDataChannel.handle(call, result: result)
      } else if ["scheduleWorkoutsFromFlutter", "clearAppleScheduledWorkouts"].contains(call.method) {
          WorkoutPlanManager.shared.handle(call, result: result)
      } else {
          result(FlutterMethodNotImplemented)
      }
  }
}
