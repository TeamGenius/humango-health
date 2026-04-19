import 'package:flutter/services.dart';

/// Flutter ↔ Native channel for the example app's session management.
/// Talks to [ExampleSessionChannel] in the iOS Runner.
///
/// The example app controls login state natively (no library setUserLoggedIn),
/// matching the pattern used in a real host app.
class ExampleSessionManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.example/session',
  );

  /// Sets the user as logged in on the native side.
  /// This assigns [ExampleHealthDataHandler] as the library delegate and
  /// starts all background monitoring (workouts, sleep, HRV).
  static Future<void> setLoggedIn() async {
    await _channel.invokeMethod('setLoggedIn');
  }

  /// Logs the user out on the native side.
  /// Stops all background monitoring and clears stored health data.
  static Future<void> setLoggedOut() async {
    await _channel.invokeMethod('setLoggedOut');
  }

  /// Starts all background monitoring (workouts + sleep).
  /// Requires that the delegate is already set (i.e. user is logged in).
  static Future<void> startBackgroundMonitoring() async {
    await _channel.invokeMethod('startBackgroundMonitoring');
  }

  /// Stops all background monitoring.
  static Future<void> stopBackgroundMonitoring() async {
    await _channel.invokeMethod('stopBackgroundMonitoring');
  }
}
