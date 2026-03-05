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

    let instance = HumangoHealthPlugin()
    
    registrar.addMethodCallDelegate(instance, channel: permissionMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutPlanMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutReadMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: sleepDataMethodChannel)
    
    permissionEventChannel.setStreamHandler(PermissionStreamHandler())
    workoutReadEventChannel.setStreamHandler(instance.workoutReadChannel)
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
      } else if ["getSleepData"].contains(call.method) {
          // Sleep data channel
          if #available(iOS 14.0, *) {
              SleepDataManager.shared.handle(call, result: result)
          } else {
              result(FlutterError(code: "UNSUPPORTED", message: "Sleep data requires iOS 14.0+", details: nil))
          }
      } else {
          result(FlutterMethodNotImplemented)
      }
  }
}

