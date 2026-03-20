import 'package:flutter/foundation.dart';
import 'package:humango_health/humango_health.dart';

/// Session + background delivery in one place (see plugin `docs/client_app_integration_guide.md`).
class HealthSyncCoordinator extends ChangeNotifier {
  HealthSyncCoordinator();

  /// Shared managers — one instance per process for stable native channel usage.
  final WorkoutReadManager workoutRead = WorkoutReadManager();
  final SleepDataManager sleep = SleepDataManager();

  /// Example logs endpoint (same as previous Sleep tab default).
  static const String defaultSleepLogsApiUrl =
      'https://humango-api-629346406456.us-central1.run.app/log';

  String? sessionStatus;
  String? backgroundDeliveryStatus;
  String? lastError;

  /// Call after credentials / user id are available. Safe to repeat (e.g. token refresh
  /// flows should re-call [ensureBackgroundDeliveryConfigured] with updated headers later).
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

  /// Idempotent: configures workout background (local storage) + sleep background (API).
  /// Native layer skips no-op persists when unchanged.
  Future<void> ensureBackgroundDeliveryConfigured({
    String sleepApiUrl = defaultSleepLogsApiUrl,
  }) async {
    lastError = null;
    try {
      await workoutRead.configureBackgroundDelivery(
        BackgroundDeliveryConfig(
          mode: BackgroundDeliveryMode.localStorage,
        ),
      );
      final sleepResult = await sleep.configureSleepBackgroundDelivery(
        SleepBackgroundDeliveryConfig(
          mode: SleepBackgroundDeliveryMode.api,
          apiURL: sleepApiUrl,
        ),
      );
      backgroundDeliveryStatus =
          'Workouts → localStorage; sleep → api (${sleepResult['mode'] ?? 'api'}) → $sleepApiUrl';
    } catch (e, st) {
      lastError = '$e';
      backgroundDeliveryStatus = 'Error: $e';
      debugPrint('HealthSyncCoordinator.ensureBackgroundDeliveryConfigured: $e\n$st');
    }
    notifyListeners();
  }
}
