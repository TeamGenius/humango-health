//
//  UserAuthStateManager.swift
//  humango_health
//
//  Tracks user login state to gate background observer auto-start.
//  Background health monitoring only starts when the user is logged in.
//

import Foundation
import Flutter

// MARK: - Notifications

extension Notification.Name {
    /// Posted whenever the user's login state changes.
    /// `userInfo["loggedIn"]` contains the new `Bool` value.
    public static let humangoUserLoginStateChanged =
        Notification.Name("com.humango.health.userLoginStateChanged")
}

/// Tracks the user's login state, persisted across app launches via UserDefaults.
///
/// HealthKit reads and background monitoring (workouts, sleep, HRV, quantity metrics)
/// only run when `isLoggedIn` is `true`. This prevents reading or syncing health data
/// before login and ensures cleanup on logout.
public class UserAuthStateManager {
    public static let shared = UserAuthStateManager()

    private let loggedInKey = "com.humango.health.userLoggedIn"
    private let userIdKey   = "com.humango.health.userId"

    private init() {}

    /// Whether the user is currently logged in.
    ///
    /// Defaults to `false` on fresh install — no background monitoring starts until
    /// the host app sets this to `true` after a successful login (native layer,
    /// e.g. your Runner session channel — there is no library Dart API for login).
    public var isLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: loggedInKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: loggedInKey)
            UserDefaults.standard.synchronize()
            NotificationCenter.default.post(
                name: .humangoUserLoginStateChanged,
                object: nil,
                userInfo: ["loggedIn": newValue]
            )
        }
    }

    /// The authenticated user's ID, persisted across app launches.
    /// Set this alongside `isLoggedIn = true` after a successful login so that
    /// background logging can attach the userId to every remote log event.
    public var userId: String? {
        get { UserDefaults.standard.string(forKey: userIdKey) }
        set {
            if let id = newValue {
                UserDefaults.standard.set(id, forKey: userIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: userIdKey)
            }
            UserDefaults.standard.synchronize()
        }
    }

    /// Completes `result` with `NOT_LOGGED_IN` when the user is not logged in.
    /// Use before HealthKit reads or starting health observers.
    @discardableResult
    public func guardLoggedInForHealthData(result: @escaping FlutterResult) -> Bool {
        guard isLoggedIn else {
            result(FlutterError(
                code: "NOT_LOGGED_IN",
                message: "Health data is only available when the user is logged in",
                details: nil
            ))
            return false
        }
        return true
    }
}
