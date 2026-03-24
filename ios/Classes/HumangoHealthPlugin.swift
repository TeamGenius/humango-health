import Flutter
import UIKit

public class HumangoHealthPlugin: NSObject, FlutterPlugin {
  /// The plugin instance registered with Flutter. Weak so it doesn't prevent deallocation.
  public static weak var shared: HumangoHealthPlugin?

  /// Host-app delegate that receives workout and sleep data ready for upload.
  /// Set this after the user logs in (e.g. from `UserSessionChannel`).
  public static var delegate: HumangoHealthDataDelegate?

  private let workoutReadChannel = WorkoutServiceChannel()

  // MARK: - Background Monitoring

  /// Triggers all subsystems to auto-start background monitoring (workouts, sleep, HRV)
  /// provided they have been previously configured/armed. Safe to call after login.
  public func startAllBackgroundMonitoring() {
      guard UserAuthStateManager.shared.isLoggedIn else {
          debugPrint("🔐 [HumangoHealth] startAllBackgroundMonitoring skipped — user not logged in")
          return
      }
      guard HumangoHealthPlugin.delegate != nil else {
          debugPrint("🔐 [HumangoHealth] startAllBackgroundMonitoring skipped — delegate not set. Assign HumangoHealthPlugin.delegate before starting monitoring.")
          return
      }
      workoutReadChannel.autoStartIfConfigured()
      SleepDataManager.shared.autoStartIfConfigured()
      HRVObserverManager.shared.autoStartIfConfigured()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let permissionMethodChannel = FlutterMethodChannel(name: "healthkit/method", binaryMessenger: registrar.messenger())
    let permissionEventChannel = FlutterEventChannel(name: "healthkit/event", binaryMessenger: registrar.messenger())
    
    // Phase 3: Workout Scheduling
    let workoutPlanMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/workoutplan", binaryMessenger: registrar.messenger())
    
    // Phase 4: Activity Reading
    let workoutReadMethodChannel = FlutterMethodChannel(name: "com.humango.workouts/read", binaryMessenger: registrar.messenger())
    
    // Phase 5: Sleep Data Reading
    let sleepDataMethodChannel = FlutterMethodChannel(name: "com.humango.health/sleep", binaryMessenger: registrar.messenger())
    // Note: no EventChannel for sleep payload updates. Background HKObserverQuery
    // delivery fires while Flutter is suspended; finalized sessions are delivered
    // directly to HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:).

    // Phase 6: Health Metrics (HRV, Resting HR, Body Fat, Weight, Height)
    let healthMetricsMethodChannel = FlutterMethodChannel(name: "com.humango.health/metrics", binaryMessenger: registrar.messenger())
    let healthMetricsHRVEventChannel = FlutterEventChannel(name: "com.humango.health/metrics/hrv_updates", binaryMessenger: registrar.messenger())

    let instance = HumangoHealthPlugin()
    shared = instance
    
    registrar.addMethodCallDelegate(instance, channel: permissionMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutPlanMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutReadMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: sleepDataMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: healthMetricsMethodChannel)
    
    permissionEventChannel.setStreamHandler(PermissionStreamHandler())
    healthMetricsHRVEventChannel.setStreamHandler(HRVStreamHandler())
    
    // MARK: - Auto-Start Monitoring
    // Workouts / Sleep / HRV: only when user is logged in and the subsystem was armed / enabled.
    instance.startAllBackgroundMonitoring()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "verifyAuthorization" {
          PermissionManager.shared.verifyAuthorization(result: result)
      } else if call.method == "requestAuthorization" {
          PermissionManager.shared.requestAuthorization(result: result)
      } else if ["readWorkouts", "startWorkoutMonitoring", "stopWorkoutMonitoring", "setImportPreferences", "enterForeground", "enterBackground"].contains(call.method) {
          // Workout read channel
          workoutReadChannel.handle(call, result: result)
      } else if ["scheduleWorkoutsFromFlutter", "clearAppleScheduledWorkouts", "requestAuthorizationForWorkoutPush", "getScheduledWorkouts", "computeWorkoutJsonHash", "removeAllScheduledWorkouts", "removeScheduledWorkouts"].contains(call.method) {
          WorkoutPlanManager.shared.handle(call, result: result)
      } else if ["getSleepData", "startSleepMonitoring", "stopSleepMonitoring", "calculateSleepPayload"].contains(call.method) {
          SleepDataManager.shared.handle(call, result: result)
      } else if ["getHealthMetric", "getLatestHealthMetric", "getAllHealthMetrics"].contains(call.method) {
          HealthMetricsManager.shared.handle(call, result: result)
      } else if ["startHRVMonitoring", "stopHRVMonitoring", "getPendingHRVUpdates", "isHRVMonitoringActive"].contains(call.method) {
          handleHRVMonitoring(call, result: result)
      } else {
          result(FlutterMethodNotImplemented)
      }
  }

  // MARK: - HRV Auto-Read (background / suspended)

  private func handleHRVMonitoring(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      switch call.method {
      case "startHRVMonitoring":
          guard UserAuthStateManager.shared.guardLoggedInForHealthData(result: result) else { return }
          HRVObserverManager.shared.startMonitoring()
          result(nil)
      case "stopHRVMonitoring":
          HRVObserverManager.shared.stopMonitoring()
          result(nil)
      case "getPendingHRVUpdates":
          guard UserAuthStateManager.shared.isLoggedIn else {
              result([])
              return
          }
          let pending = HRVObserverManager.shared.retrievePendingHRVUpdates()
          result(pending)
      case "isHRVMonitoringActive":
          guard UserAuthStateManager.shared.isLoggedIn else {
              result(false)
              return
          }
          result(HRVObserverManager.shared.isMonitoringEnabled)
      default:
          result(FlutterMethodNotImplemented)
      }
  }

  /// Stops all active background monitors and clears all stored health data.
  /// Call this when the user logs out so the next login starts from a clean state.
  public func logout() {
      UserAuthStateManager.shared.isLoggedIn = false
      clearAllDataOnLogout()
  }

  private func clearAllDataOnLogout() {
      debugPrint("🔐 [HumangoHealth] User logged out — stopping all monitors and clearing data")

      // Stop workout monitoring and clear background delivery config
      workoutReadChannel.stopAndClearAll()

      // Stop sleep monitoring, clear stored sleep data and config
      SleepDataManager.shared.stopAndClearAll()

      // Clear scheduled workouts stored in Apple Watch
      ScheduledWorkoutStore.shared.clearAll()

      // Stop HRV observer and clear pending data
      HRVObserverManager.shared.stopAndClearAll()

      debugPrint("🔐 [HumangoHealth] ✅ All data cleared on logout")

  }
}

