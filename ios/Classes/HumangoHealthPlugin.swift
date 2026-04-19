import Flutter
import UIKit

public class HumangoHealthPlugin: NSObject, FlutterPlugin {
  /// The plugin instance registered with Flutter. Weak so it doesn't prevent deallocation.
  public static weak var shared: HumangoHealthPlugin?

  /// Host-app delegate that receives workout, sleep, and quantity-metric batches ready for upload.
  /// Set this after the user logs in (e.g. from `UserSessionChannel`).
  public static var delegate: HumangoHealthDataDelegate?

  private let workoutReadChannel = WorkoutServiceChannel.shared

  // MARK: - Background Monitoring

  /// Starts background monitoring for **workouts and sleep**.
  /// Call this on every app open after setting `HumangoHealthPlugin.delegate`.
  /// Idempotent — safe to call when monitoring is already running.
  /// For health metrics, call `startMetricsMonitoring(for:)` separately.
  public func startActivityBackgroundMonitoring() {

      workoutReadChannel.startMonitoring()
  }

  /// Stops background monitoring for **workouts and sleep**.
  /// Does not affect health metrics — call `stopMetricsMonitoring(for:)` for those.
  /// Call `logout()` to stop all monitors and clear all stored data.
  public func stopActivityBackgroundMonitoring() {
      workoutReadChannel.stopAndClearAll()
  }

  /// Starts background monitoring for **sleep data** only.
  /// Call this on every app open after setting `HumangoHealthPlugin.delegate`.
  /// Idempotent — safe to call when monitoring is already running.
  public func startSleepBackgroundMonitoring() {
      SleepDataManager.shared.startMonitoring()
  }

  /// Stops background monitoring for **sleep data** only.
  /// Does not affect workouts or health metrics.
  /// Call `logout()` to stop all monitors and clear all stored data.
  public func stopSleepBackgroundMonitoring() {
      SleepDataManager.shared.stopAndClearAll()
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
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      if call.method == "verifyAuthorization" {
          PermissionManager.shared.verifyAuthorization(result: result)
      } else if call.method == "requestAuthorization" {
          let types = (call.arguments as? [String: Any])?["types"] as? [String]
          PermissionManager.shared.requestAuthorization(typeIdentifiers: types, result: result)
      } else if ["readWorkouts", "startWorkoutMonitoring", "stopWorkoutMonitoring", "setImportPreferences", "fetchAllWorkouts"].contains(call.method) {
          // Workout read channel
          workoutReadChannel.handle(call, result: result)
      } else if ["scheduleWorkoutsFromFlutter", "clearAppleScheduledWorkouts", "requestAuthorizationForWorkoutPush", "getScheduledWorkouts", "computeWorkoutJsonHash", "removeAllScheduledWorkouts", "removeScheduledWorkouts"].contains(call.method) {
          WorkoutPlanManager.shared.handle(call, result: result)
      } else if ["getSleepData", "calculateSleepPayload", "fetchSleepSamples"].contains(call.method) {
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

  // MARK: - Public Native iOS Workout Read API

  /// Fetch completed workouts within a date range as JSON strings.
  /// Applies the user's import preferences (running / cycling / swimming exclusions).
  ///
  /// ```swift
  /// let end   = Date()
  /// let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
  ///
  /// let workouts = try await HumangoHealthPlugin.shared?.readWorkouts(
  ///     startDate: start, endDate: end
  /// ) ?? []
  ///
  /// for json in workouts {
  ///     if let data = json.data(using: .utf8),
  ///        let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
  ///         print(obj["sport"] ?? "", obj["duration"] ?? "")
  ///     }
  /// }
  /// ```
  public func readWorkouts(startDate: Date, endDate: Date) async throws -> [String] {
      try await workoutReadChannel.readWorkouts(startDate: startDate, endDate: endDate)
  }

  /// Fetch ALL workouts within a date range as JSON strings, ignoring import preferences.
  ///
  /// ```swift
  /// let all = try await HumangoHealthPlugin.shared?.fetchAllWorkouts(
  ///     startDate: start, endDate: end
  /// ) ?? []
  /// ```
  public func fetchAllWorkouts(startDate: Date, endDate: Date) async throws -> [String] {
      try await workoutReadChannel.fetchAllWorkouts(startDate: startDate, endDate: endDate)
  }

  /// Resolve whether a workout (by HealthKit UUID) was created from a scheduled WorkoutKit workout.
  /// Returns `workoutPlanId` and `scheduledWorkoutId` when a match is found in `ScheduledWorkoutStore`.
  ///
  /// **Important:** This calls `workout.workoutPlan` which is an async WorkoutKit property that
  /// may hang when the network is unavailable. The client app should wrap this call in a timeout.
  ///
  /// ```swift
  /// let info = await HumangoHealthPlugin.shared?.resolveScheduledWorkoutId(
  ///     workoutUUID: "E3F1A2B4-..."
  /// ) ?? [:]
  /// if info["isScheduledWorkout"] as? Bool == true {
  ///     let scheduleId = info["scheduledWorkoutId"] as? String
  /// }
  /// ```
  public func resolveScheduledWorkoutId(workoutUUID: String) async -> [String: Any] {
      await workoutReadChannel.resolveScheduledWorkoutId(workoutUUID: workoutUUID)
  }

  // MARK: - Public Native iOS Health Metrics Monitoring

  /// Start monitoring one or more health metric types.
  /// Foreground: live HKAnchoredObjectQueryDescriptor stream.
  /// Background: HKObserverQuery + enableBackgroundDelivery(immediate).
  /// Fires `HumangoHealthDataDelegate.onHealthMetricReady` with current-day samples on each notification.
  /// Call this on every app open (after setting delegate) for each metric type you want monitored.
  /// Idempotent — safe to call when a type is already being monitored.
  public func startMetricsMonitoring(for types: [HealthMetricType]) {
      types.forEach { HealthMetricsManager.shared.startMonitoring($0) }
  }

  /// Stop monitoring one or more health metric types.
  public func stopMetricsMonitoring(for types: [HealthMetricType]) {
      types.forEach { HealthMetricsManager.shared.stopMonitoring($0) }
  }

  /// Stops background monitoring for **all health metric types**.
  /// Does not affect workouts or sleep.
  /// Call `logout()` to stop all monitors and clear all stored data.
  public func stopAllMetricsMonitoring() {
      HealthMetricsManager.shared.stopAllMonitoring()
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

