import Flutter
import UIKit

public class HumangoHealthPlugin: NSObject, FlutterPlugin {
  /// The plugin instance registered with Flutter. Weak so it doesn't prevent deallocation.
  public static weak var shared: HumangoHealthPlugin?

  /// Host-app delegate that receives workout, sleep, and quantity-metric batches ready for upload.
  /// Set this after the user logs in (e.g. from `UserSessionChannel`).
  public static var delegate: HumangoHealthDataDelegate?

  private let workoutReadChannel = WorkoutServiceChannel()

  // MARK: - Background Monitoring

    /// Triggers monitoring-capable subsystems to auto-start background monitoring (workouts, sleep)
  /// provided they have been previously configured/armed. Safe to call after login.
  public func startAllBackgroundMonitoring() {
      guard guardMonitoringPreconditions("startAllBackgroundMonitoring") else { return }
      SleepRemoteLogger.log(.info, step: "startAllBackgroundMonitoring", message: "starting all subsystems", context: ["class": "HumangoHealthPlugin", "method": "startAllBackgroundMonitoring"])
      workoutReadChannel.autoStartIfConfigured()
      SleepDataManager.shared.autoStartIfConfigured()
  }

  /// Starts background monitoring for **activity/workout reading** only.
  /// Requires the user to be logged in and `HumangoHealthPlugin.delegate` to be set.
  public func startActivityBackgroundMonitoring() {
      guard guardMonitoringPreconditions("startActivityBackgroundMonitoring") else { return }
      SleepRemoteLogger.log(.info, step: "startActivityBackgroundMonitoring", message: "starting activity subsystem", context: ["class": "HumangoHealthPlugin", "method": "startActivityBackgroundMonitoring"])
      workoutReadChannel.autoStartIfConfigured()
  }

  /// Starts background monitoring for **sleep data** only.
  /// Requires the user to be logged in and `HumangoHealthPlugin.delegate` to be set.
  public func startSleepBackgroundMonitoring() {
      guard guardMonitoringPreconditions("startSleepBackgroundMonitoring") else { return }
      SleepRemoteLogger.log(.info, step: "startSleepBackgroundMonitoring", message: "starting sleep subsystem", context: ["class": "HumangoHealthPlugin", "method": "startSleepBackgroundMonitoring"])
      SleepDataManager.shared.autoStartIfConfigured()
  }

  /// Shared precondition check for all monitoring entry points.
  private func guardMonitoringPreconditions(_ caller: String) -> Bool {
      guard UserAuthStateManager.shared.isLoggedIn else {
          debugPrint("🔐 [HumangoHealth] \(caller) skipped — user not logged in")
          SleepRemoteLogger.log(.warn, step: caller, message: "skipped — user not logged in", context: ["class": "HumangoHealthPlugin", "method": "guardMonitoringPreconditions"])
          return false
      }
      guard HumangoHealthPlugin.delegate != nil else {
          debugPrint("🔐 [HumangoHealth] \(caller) skipped — delegate not set. Assign HumangoHealthPlugin.delegate before starting monitoring.")
          SleepRemoteLogger.log(.warn, step: caller, message: "skipped — delegate nil", context: ["class": "HumangoHealthPlugin", "method": "guardMonitoringPreconditions"])
          return false
      }
      return true
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
    // Flutter channel methods: fetchHealthMetric, startMetricMonitoring, stopMetricMonitoring, stopAllMetricMonitoring.
    // Native iOS callers use HumangoHealthPlugin.shared?.fetchHealthMetric / startMetricsMonitoring.
    // Monitoring delivers current-day samples via HumangoHealthDataDelegate.onHealthMetricReady.

    let instance = HumangoHealthPlugin()
    shared = instance
    
    registrar.addMethodCallDelegate(instance, channel: permissionMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutPlanMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: workoutReadMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: sleepDataMethodChannel)
    registrar.addMethodCallDelegate(instance, channel: healthMetricsMethodChannel)
    
    permissionEventChannel.setStreamHandler(PermissionStreamHandler())
    
    // MARK: - Auto-Start Monitoring
        // Workouts / Sleep: only when user is logged in and the subsystem was armed / enabled.
    instance.startAllBackgroundMonitoring()
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "verifyAuthorization" {
          PermissionManager.shared.verifyAuthorization(result: result)
      } else if call.method == "requestAuthorization" {
          PermissionManager.shared.requestAuthorization(result: result)
      } else if ["readWorkouts", "startWorkoutMonitoring", "stopWorkoutMonitoring", "setImportPreferences", "fetchAllWorkouts"].contains(call.method) {
          // Workout read channel
          workoutReadChannel.handle(call, result: result)
      } else if ["scheduleWorkoutsFromFlutter", "clearAppleScheduledWorkouts", "requestAuthorizationForWorkoutPush", "getScheduledWorkouts", "computeWorkoutJsonHash", "removeAllScheduledWorkouts", "removeScheduledWorkouts"].contains(call.method) {
          WorkoutPlanManager.shared.handle(call, result: result)
      } else if ["getSleepData", "startSleepMonitoring", "stopSleepMonitoring", "calculateSleepPayload"].contains(call.method) {
          SleepDataManager.shared.handle(call, result: result)
      } else if ["fetchHealthMetric", "startMetricMonitoring", "stopMetricMonitoring", "stopAllMetricMonitoring"].contains(call.method) {
          HealthMetricsManager.shared.handle(call, result: result)
      } else {
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

      // Stop all active health metric monitors
      HealthMetricsManager.shared.stopAllMonitoring()

      // Clear scheduled workouts stored in Apple Watch
      ScheduledWorkoutStore.shared.clearAll()

      debugPrint("🔐 [HumangoHealth] ✅ All data cleared on logout")

  }

  // MARK: - Public Native iOS Health Metrics Monitoring

  /// Start monitoring one or more health metric types.
  /// Foreground: live HKAnchoredObjectQueryDescriptor stream.
  /// Background: HKObserverQuery + enableBackgroundDelivery(immediate).
  /// Fires `HumangoHealthDataDelegate.onHealthMetricReady` with current-day samples on each notification.
  /// Requires `HumangoHealthPlugin.delegate` to be set and the user to be logged in.
  public func startMetricsMonitoring(for types: [HealthMetricType]) {
      guard guardMonitoringPreconditions("startMetricsMonitoring") else { return }
      SleepRemoteLogger.log(.info, step: "startMetricsMonitoring", message: "starting metric monitors", context: [
          "class": "HumangoHealthPlugin",
          "types": types.map { $0.key }.joined(separator: ", "),
      ])
      types.forEach { HealthMetricsManager.shared.startMonitoring($0) }
  }

  /// Stop monitoring one or more health metric types.
  public func stopMetricsMonitoring(for types: [HealthMetricType]) {
      SleepRemoteLogger.log(.info, step: "stopMetricsMonitoring", message: "stopping metric monitors", context: [
          "class": "HumangoHealthPlugin",
          "types": types.map { $0.key }.joined(separator: ", "),
      ])
      types.forEach { HealthMetricsManager.shared.stopMonitoring($0) }
  }

  // MARK: - Public Native iOS Health Metrics Fetch API

  /// On-demand query for a single metric type within a date range.
  /// All numeric values are raw Double — no rounding applied.
  public func fetchHealthMetric(
      _ type: HealthMetricType,
      startDate: Date,
      endDate: Date
  ) async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchMetric(type, startDate: startDate, endDate: endDate)
  }

  /// On-demand query for the most recent sample of a single metric type.
  public func fetchLatestHealthMetric(_ type: HealthMetricType) async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchLatestMetric(type)
  }

  /// On-demand query for all supported metric types within a date range.
  public func fetchAllHealthMetrics(startDate: Date, endDate: Date) async -> [String: Any] {
      await HealthMetricsManager.shared.fetchAllMetrics(startDate: startDate, endDate: endDate)
  }

  // MARK: - Per-type convenience fetch wrappers

  /// Fetch HRV (SDNN) samples in ms. Raw Double — no rounding.
  public func fetchHRV(startDate: Date, endDate: Date) async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchMetric(.heartRateVariabilitySDNN, startDate: startDate, endDate: endDate)
  }
  /// Fetch the most recent HRV (SDNN) sample.
  public func fetchLatestHRV() async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchLatestMetric(.heartRateVariabilitySDNN)
  }

  /// Fetch resting heart rate samples in bpm. Raw Double — no rounding.
  public func fetchRestingHeartRate(startDate: Date, endDate: Date) async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchMetric(.restingHeartRate, startDate: startDate, endDate: endDate)
  }
  /// Fetch the most recent resting heart rate sample.
  public func fetchLatestRestingHeartRate() async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchLatestMetric(.restingHeartRate)
  }

  /// Fetch body fat percentage samples (%). Raw Double — no rounding.
  public func fetchBodyFatPercentage(startDate: Date, endDate: Date) async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchMetric(.bodyFatPercentage, startDate: startDate, endDate: endDate)
  }
  /// Fetch the most recent body fat percentage sample.
  public func fetchLatestBodyFatPercentage() async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchLatestMetric(.bodyFatPercentage)
  }

  /// Fetch weight (body mass) samples in kg. Raw Double — no rounding.
  public func fetchWeight(startDate: Date, endDate: Date) async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchMetric(.bodyMass, startDate: startDate, endDate: endDate)
  }
  /// Fetch the most recent weight sample.
  public func fetchLatestWeight() async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchLatestMetric(.bodyMass)
  }

  /// Fetch height samples in cm. Raw Double — no rounding.
  public func fetchHeight(startDate: Date, endDate: Date) async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchMetric(.height, startDate: startDate, endDate: endDate)
  }
  /// Fetch the most recent height sample.
  public func fetchLatestHeight() async throws -> [String: Any] {
      try await HealthMetricsManager.shared.fetchLatestMetric(.height)
  }
}

