//
//  user_session_manager.dart
//  humango_health
//
//  Controls user login/logout state for the HumangoHealth library.
//  Background observer auto-start is gated on this state.
//

import 'package:flutter/services.dart';

/// Manages user session state for the HumangoHealth library.
///
/// Call [setUserLoggedIn] after a successful login/logout so the library can:
/// - **Login (`true`)**: allow background health observers to auto-start on the
///   next app launch if they were previously configured.
/// - **Logout (`false`)**: immediately stop all active monitoring (workouts,
///   sleep, activities) and wipe all stored data including:
///   - Workout background delivery configuration
///   - Sleep background delivery configuration
///   - Locally stored workout and sleep records
///   - Scheduled workouts on Apple Watch
///
/// ### Typical usage
///
/// ```dart
/// // After successful login
/// await UserSessionManager.setUserLoggedIn(true);
///
/// // After logout
/// await UserSessionManager.setUserLoggedIn(false);
/// ```
///
/// ### App-launch flow
///
/// | State                              | Auto-start? |
/// |------------------------------------|-------------|
/// | Not logged in (fresh install)      | No          |
/// | Logged in, no background config    | No          |
/// | Logged in, background configured   | Yes         |
class UserSessionManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/session',
  );

  /// Sets the user's logged-in state.
  ///
  /// Pass `true` after login and `false` after logout.
  /// On `false`, all background monitoring stops and stored data is cleared
  /// immediately on the native side.
  static Future<void> setUserLoggedIn(bool loggedIn) async {
    await _channel.invokeMethod('setUserLoginState', {'loggedIn': loggedIn});
  }
}
