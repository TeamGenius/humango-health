import Flutter
import UIKit

public class HumangoHealthPlugin: NSObject, FlutterPlugin {
  private let workoutReadChannel = WorkoutServiceChannel()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let permissionMethodChannel = FlutterMethodChannel(name: "healthkit/method", binaryMessenger: registrar.messenger())
    let permissionEventChannel = FlutterEventChannel(name: "healthkit/event", binaryMessenger: registrar.messenger())
    
    // Phase 3: Workout Scheduling
    let workoutPlanMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/workoutplan", binaryMessenger: registrar.messenger())
    
    // Phase 4: Activity Reading
    let workoutReadMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/read", binaryMessenger: registrar.messenger())
    let workoutReadEventChannel = FlutterEventChannel(name: "com.humango.workouts/read/stream", binaryMessenger: registrar.messenger())
    
    // Phase 5: Sleep Data Reading
    let sleepDataMethodChannel = FlutterMethodChannel(name: "com.humango.health/sleep", binaryMessenger: registrar.messenger())
    let sleepDataEventChannel = FlutterEventChannel(name: "com.humango.health/sleep/stream", binaryMessenger: registrar.messenger())
    
    // Phase 6: Health Metrics (HRV, Resting HR, Body Fat, Weight, Height)
    let healthMetricsMethodChannel = FlutterMethodChannel(name: "com.humango.health/metrics", binaryMessenger: registrar.messenger())

    let instance = HumangoHealthPlugin()
    
    registrar.addMethodCallDelegate(instance, channel: permissionMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutPlanMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutReadMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: sleepDataMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: healthMetricsMethodChannel)
    
    permissionEventChannel.setStreamHandler(PermissionStreamHandler())
    workoutReadEventChannel.setStreamHandler(instance.workoutReadChannel)
    
    // Set up sleep data event channel stream handler
    if #available(iOS 14.0, *) {
        sleepDataEventChannel.setStreamHandler(SleepDataManager.shared)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "verifyAuthorization" {
          PermissionManager.shared.verifyAuthorization(result: result)
      } else if call.method == "requestAuthorization" {
          PermissionManager.shared.requestAuthorization(result: result)
      } else if ["readWorkouts", "startWorkoutMonitoring", "stopWorkoutMonitoring", "getLocalWorkouts", "configureBackgroundDelivery", "setImportPreferences", "enterForeground", "enterBackground"].contains(call.method) {
          // Workout read channel
          workoutReadChannel.handle(call, result: result)
      } else if ["scheduleWorkoutsFromFlutter", "clearAppleScheduledWorkouts", "requestAuthorizationForWorkoutPush", "getScheduledWorkouts"].contains(call.method) {
          WorkoutPlanManager.shared.handle(call, result: result)
      } else if ["getSleepData", "startSleepMonitoring", "stopSleepMonitoring", "fetchStoredSleepData", "clearStoredSleepData", "enterSleepForeground", "enterSleepBackground"].contains(call.method) {
          // Sleep data channel - remap foreground/background methods to avoid conflict with workout methods
          var mappedCall = call
          if call.method == "enterSleepForeground" {
              mappedCall = FlutterMethodCall(methodName: "enterForeground", arguments: call.arguments)
          } else if call.method == "enterSleepBackground" {
              mappedCall = FlutterMethodCall(methodName: "enterBackground", arguments: call.arguments)
          }
          
          if #available(iOS 14.0, *) {
              SleepDataManager.shared.handle(mappedCall, result: result)
          } else {
              result(FlutterError(code: "UNSUPPORTED", message: "Sleep data requires iOS 14.0+", details: nil))
          }
      } else if ["getHealthMetric", "getLatestHealthMetric", "getAllHealthMetrics"].contains(call.method) {
          // Health metrics channel (HRV, resting HR, body fat, weight, height)
          HealthMetricsManager.shared.handle(call, result: result)
      } else {
          result(FlutterMethodNotImplemented)
      }
  }
}

