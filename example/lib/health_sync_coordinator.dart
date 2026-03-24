import 'package:flutter/foundation.dart';
import 'package:humango_health/humango_health.dart';
import 'example_session_manager.dart';

/// Session management in one place (see plugin `docs/client_app_integration_guide.md`).
class HealthSyncCoordinator extends ChangeNotifier {
  HealthSyncCoordinator();

  /// Shared managers — one instance per process for stable native channel usage.
  final WorkoutReadManager workoutRead = WorkoutReadManager();
  final SleepDataManager sleep = SleepDataManager();

  String? sessionStatus;
  String? lastError;

  /// Call after credentials / user id are available. Safe to repeat.
  Future<void> setUserLoggedIn({required bool loggedIn, String? userId}) async {
    lastError = null;
    try {
      if (loggedIn) {
        await ExampleSessionManager.setLoggedIn();
        sessionStatus = userId != null && userId.isNotEmpty
            ? 'Logged in as "$userId"'
            : 'Logged in';
      } else {
        await ExampleSessionManager.setLoggedOut();
        sessionStatus = 'Logged out — session cleared';
      }
    } catch (e, st) {
      lastError = '$e';
      sessionStatus = 'Error: $e';
      debugPrint('HealthSyncCoordinator.setUserLoggedIn: $e\n$st');
    }
    notifyListeners();
  }
}
