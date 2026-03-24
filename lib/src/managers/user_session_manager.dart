//
//  user_session_manager.dart
//  humango_health
//
//  Previously controlled user login/logout state via a Flutter method channel.
//  The `setUserLoginState` channel method has been removed from the library.
//  Login state is now managed by the host app's native Runner layer
//  (e.g. ExampleSessionChannel in the example app, UserSessionChannel in
//  the production app) so the library has no opinions about who is logged in.
//

import 'package:flutter/services.dart';

/// Manages credentials that the native Runner layer needs during background
/// execution (athleteId, accessToken stored in UserDefaults).
///
/// Login / logout state is now controlled natively by the host app's Runner —
/// set [HumangoHealthPlugin.delegate] and call
/// [HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()] after login,
/// and [HumangoHealthPlugin.shared?.logout()] after logout.
class UserSessionManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/session',
  );

  /// Stores [athleteId] and [accessToken] in UserDefaults so the native
  /// SleepUploadService / background Pipeline can read them during background
  /// execution. Call this after login once the credentials are available.
  static Future<void> saveCredentials({
    required String athleteId,
    String? accessToken,
  }) async {
    await _channel.invokeMethod('saveCredentials', {
      'athleteId': athleteId,
      if (accessToken != null) 'accessToken': accessToken,
    });
  }
}
