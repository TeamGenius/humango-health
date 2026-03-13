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

    private let key = "com.humango.health.userLoggedIn"

    private init() {}

    /// Whether the user is currently logged in.
    ///
    /// Defaults to `false` on fresh install — no background monitoring starts until
    /// Flutter explicitly calls `setUserLoggedIn(true)` after a successful login.
    var isLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            UserDefaults.standard.synchronize()
        }
    }
}
