//
//  MonitoringConfig.swift
//  humango_health
//
//  Persisted flags that control which monitoring subsystems auto-start on app relaunch.
//
//  Lifecycle:
//   • A subsystem flag starts as `false` (never enabled, or after login reset).
//   • The host-app explicitly arms a subsystem by calling one of:
//       HumangoHealthPlugin.shared?.startActivityBackgroundMonitoring()
//       HumangoHealthPlugin.shared?.startSleepBackgroundMonitoring()
//       HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()
//       HumangoHealthPlugin.shared?.startMetricsMonitoring(for: [...])
//     Each call sets the corresponding flag(s) to `true`, then starts the observer.
//   • On every subsequent relaunch `autoStartIfConfigured()` in each manager reads
//     its flag — if `true`, it starts; if `false`, it skips.
//   • On new login (isLoggedIn: false → true) all flags are reset to `false` so
//     each login begins from a clean slate.
//

import Foundation

/// Persisted flags that gate automatic monitoring restarts across app relaunches.
///
/// Flags are stored in `UserDefaults` so they survive process termination.
/// All keys are prefixed with `"com.humango.health.monitoring."` to avoid collisions.
public class MonitoringConfig {

    public static let shared = MonitoringConfig()

    // MARK: - Storage keys

    private let workoutsKey   = "com.humango.health.monitoring.workouts"
    private let sleepKey      = "com.humango.health.monitoring.sleep"
    private let metricKeysKey = "com.humango.health.monitoring.metricKeys"

    private init() {}

    // MARK: - Workout / Activity flag

    /// `true` after `startActivityBackgroundMonitoring()` or `startAllBackgroundMonitoring()`.
    /// Cleared on new login.
    var workoutsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: workoutsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: workoutsKey)
            UserDefaults.standard.synchronize()
        }
    }

    // MARK: - Sleep flag

    /// `true` after `startSleepBackgroundMonitoring()` or `startAllBackgroundMonitoring()`.
    /// Cleared on new login.
    var sleepEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: sleepKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: sleepKey)
            UserDefaults.standard.synchronize()
        }
    }

    // MARK: - Health metric flags

    /// Keys of metric types whose observers should auto-restart on relaunch.
    /// Updated by `startMetricsMonitoring(for:)` / `stopMetricsMonitoring(for:)`.
    var enabledMetricKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: metricKeysKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: metricKeysKey)
            UserDefaults.standard.synchronize()
        }
    }

    /// Adds a single metric key to the persisted enabled set.
    func enableMetric(_ key: String) {
        var keys = enabledMetricKeys
        keys.insert(key)
        enabledMetricKeys = keys
    }

    /// Removes a single metric key from the persisted enabled set.
    func disableMetric(_ key: String) {
        var keys = enabledMetricKeys
        keys.remove(key)
        enabledMetricKeys = keys
    }

    // MARK: - Reset

    /// Clears all monitoring flags. Called when the user logs in so each login
    /// starts from a clean slate — the host-app must re-arm subsystems explicitly.
    public func clearAll() {
        workoutsEnabled   = false
        sleepEnabled      = false
        enabledMetricKeys = []
        debugPrint("[MonitoringConfig] ✅ All monitoring flags cleared (new login)")
    }
}
