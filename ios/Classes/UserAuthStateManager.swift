//
//  UserAuthStateManager.swift
//  humango_health
//
//  Tracks user login state to gate background observer auto-start.
//  Background health monitoring only starts when the user is logged in.
//

import Foundation

/// Tracks the user's login state, persisted across app launches via UserDefaults.
///
/// Background monitoring (workout, sleep, activities) only auto-starts on app launch
/// when `isLoggedIn` is `true`. This prevents unintended monitoring before the user
/// logs in and ensures all data is cleared cleanly on logout.
class UserAuthStateManager {
    static let shared = UserAuthStateManager()

    private let loggedInKey = "com.humango.health.userLoggedIn"
    private let userIdKey   = "com.humango.health.userId"

    private init() {}

    /// Whether the user is currently logged in.
    ///
    /// Defaults to `false` on fresh install — no background monitoring starts until
    /// Flutter explicitly calls `setUserLoggedIn(true)` after a successful login.
    var isLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: loggedInKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: loggedInKey)
            UserDefaults.standard.synchronize()
        }
    }

    /// The authenticated user's ID, persisted across app launches.
    /// Set this alongside `isLoggedIn = true` after a successful login so that
    /// background logging can attach the userId to every remote log event.
    var userId: String? {
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
}
