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

    // Phase 6: Health Metrics (HRV, Resting HR, Body Fat, Weight, Height)
    let healthMetricsMethodChannel = FlutterMethodChannel(name: "com.humango.health/metrics", binaryMessenger: registrar.messenger())
    let healthMetricsHRVEventChannel = FlutterEventChannel(name: "com.humango.health/metrics/hrv_updates", binaryMessenger: registrar.messenger())

    // User Session: login/logout state gate for background observer auto-start
    let sessionMethodChannel = FlutterMethodChannel(name: "com.humango.health/session", binaryMessenger: registrar.messenger())

    let instance = HumangoHealthPlugin()
    
    registrar.addMethodCallDelegate(instance, channel: permissionMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutPlanMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutReadMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: sleepDataMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: healthMetricsMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: sessionMethodChannel)
    
    permissionEventChannel.setStreamHandler(PermissionStreamHandler())
    workoutReadEventChannel.setStreamHandler(instance.workoutReadChannel)
    healthMetricsHRVEventChannel.setStreamHandler(HRVStreamHandler())
    
    // MARK: - Auto-Start Monitoring
    // Workouts / Sleep: only when user is logged in and API was previously configured.
    // HRV: always auto-start on launch — no user interaction required; HRV is read
    //      automatically whenever HealthKit is updated (foreground, background, suspended).
    instance.workoutReadChannel.autoStartIfConfigured()
    if #available(iOS 14.0, *) {
        SleepDataManager.shared.autoStartIfConfigured()
    }
    HRVObserverManager.shared.autoStartIfConfigured()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "verifyAuthorization" {
          PermissionManager.shared.verifyAuthorization(result: result)
      } else if call.method == "requestAuthorization" {
          PermissionManager.shared.requestAuthorization(result: result)
      } else if ["readWorkouts", "startWorkoutMonitoring", "stopWorkoutMonitoring", "configureBackgroundDelivery", "setImportPreferences", "enterForeground", "enterBackground"].contains(call.method) {
          // Workout read channel
          workoutReadChannel.handle(call, result: result)
      } else if ["scheduleWorkoutsFromFlutter", "clearAppleScheduledWorkouts", "requestAuthorizationForWorkoutPush", "getScheduledWorkouts", "computeWorkoutJsonHash"].contains(call.method) {
          WorkoutPlanManager.shared.handle(call, result: result)
      } else if ["getSleepData", "startSleepMonitoring", "stopSleepMonitoring", "fetchStoredSleepData", "clearStoredSleepData", "enterSleepForeground", "enterSleepBackground", "configureSleepSession", "getSleepSessionStatus", "resetSleepSession", "configureSleepBackgroundDelivery", "getLocalSleepSessions"].contains(call.method) {
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
          HealthMetricsManager.shared.handle(call, result: result)
      } else if ["startHRVMonitoring", "stopHRVMonitoring", "getPendingHRVUpdates", "isHRVMonitoringActive"].contains(call.method) {
          handleHRVMonitoring(call, result: result)
      } else if call.method == "setUserLoginState" {
          handleSetUserLoginState(call, result: result)
      } else {
          result(FlutterMethodNotImplemented)
      }
  }

  // MARK: - HRV Auto-Read (background / suspended)

  private func handleHRVMonitoring(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      switch call.method {
      case "startHRVMonitoring":
          HRVObserverManager.shared.startMonitoring()
          result(nil)
      case "stopHRVMonitoring":
          HRVObserverManager.shared.stopMonitoring()
          result(nil)
      case "getPendingHRVUpdates":
          let pending = HRVObserverManager.shared.retrievePendingHRVUpdates()
          result(pending)
      case "isHRVMonitoringActive":
          result(HRVObserverManager.shared.isMonitoringEnabled)
      default:
          result(FlutterMethodNotImplemented)
      }
  }

  // MARK: - User Session

  private func handleSetUserLoginState(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      guard let args = call.arguments as? [String: Any],
            let loggedIn = args["loggedIn"] as? Bool else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing or invalid 'loggedIn' boolean", details: nil))
          return
      }

      UserAuthStateManager.shared.isLoggedIn = loggedIn

      // Persist userId alongside login state so background loggers can attach it
      if loggedIn, let userId = args["userId"] as? String {
          UserAuthStateManager.shared.userId = userId
      } else if !loggedIn {
          UserAuthStateManager.shared.userId = nil
      }

      debugPrint("🔐 [HumangoHealth] User login state set to: \(loggedIn), userId=\(UserAuthStateManager.shared.userId ?? "nil")")

      if !loggedIn {
          clearAllDataOnLogout()
      }

      result(nil)
  }

  private func clearAllDataOnLogout() {
      debugPrint("🔐 [HumangoHealth] User logged out — stopping all monitors and clearing data")

      // Stop workout monitoring and clear background delivery config
      workoutReadChannel.stopAndClearAll()

      // Stop sleep monitoring, clear stored sleep data and config
      if #available(iOS 14.0, *) {
          SleepDataManager.shared.stopAndClearAll()
      }

      // Clear scheduled workouts stored in Apple Watch
      ScheduledWorkoutStore.shared.clearAll()

      // Clear workout record store (push-dedup tracking)
      Task {
          await WorkoutRecordStore.shared.clearAll()
      }

      // Stop HRV observer and clear pending data
      HRVObserverManager.shared.stopAndClearAll()

      // Stop HRV observer and clear pending data
      HRVObserverManager.shared.stopAndClearAll()

      debugPrint("🔐 [HumangoHealth] ✅ All data cleared on logout")
      
  }
}

