import 'package:flutter/foundation.dart';
import 'package:humango_health/humango_health.dart';

/// Session + background delivery in one place (see plugin `docs/client_app_integration_guide.md`).
class HealthSyncCoordinator extends ChangeNotifier {
  HealthSyncCoordinator();

  /// Shared managers — one instance per process for stable native channel usage.
  final WorkoutReadManager workoutRead = WorkoutReadManager();
  final SleepDataManager sleep = SleepDataManager();

  String? sessionStatus;
  String? backgroundDeliveryStatus;
  String? lastError;

  /// Call after credentials / user id are available. Safe to repeat.
  Future<void> setUserLoggedIn({
    required bool loggedIn,
    String? userId,
    bool configureBackground = true,
  }) async {
    lastError = null;
    try {
      await UserSessionManager.setUserLoggedIn(
        loggedIn,
        userId: loggedIn && (userId?.isNotEmpty ?? false) ? userId : null,
      );
      sessionStatus = loggedIn && userId != null && userId.isNotEmpty
          ? 'Logged in as "$userId"'
          : (loggedIn ? 'Logged in' : 'Logged out — session cleared');
      if (loggedIn && configureBackground) {
        await ensureBackgroundDeliveryConfigured();
      } else if (!loggedIn) {
        backgroundDeliveryStatus = null;
      }
    } catch (e, st) {
      lastError = '$e';
      sessionStatus = 'Error: $e';
      debugPrint('HealthSyncCoordinator.setUserLoggedIn: $e\n$st');
    }
    notifyListeners();
  }

  /// Idempotent: arms workout stream/pending + sleep local session queue (no plugin HTTP).
  Future<void> ensureBackgroundDeliveryConfigured() async {
    lastError = null;
    try {
      await workoutRead.configureBackgroundDelivery(const BackgroundDeliveryConfig());
      final sleepResult = await sleep.configureSleepBackgroundDelivery(
        const SleepBackgroundDeliveryConfig(),
      );
      backgroundDeliveryStatus =
          'Workouts + sleep → local pending (${sleepResult['mode'] ?? 'localStorage'}) — upload from app';
    } catch (e, st) {
      lastError = '$e';
      backgroundDeliveryStatus = 'Error: $e';
      debugPrint('HealthSyncCoordinator.ensureBackgroundDeliveryConfigured: $e\n$st');
    }
    notifyListeners();
  }
}
