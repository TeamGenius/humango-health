//
//  sleep_data_manager.dart
//  humango_health
//
//  Dart manager for fetching and monitoring sleep data from Apple HealthKit
//  Supports: one-shot fetch, background monitoring (foreground Descriptor + background Observer)
//

import 'package:flutter/services.dart';
import '../models/sleep_sample.dart';
import '../models/sleep_background_delivery_config.dart';

/// Manager for fetching and monitoring sleep data from Apple HealthKit.
///
/// Provides access to sleep analysis data including sleep stages
/// (inBed, awake, asleepCore, asleepDeep, asleepREM) with support for:
/// - One-shot data fetch for a configurable time range
/// - Background monitoring: foreground uses [HKAnchoredObjectQueryDescriptor],
///   background uses [HKObserverQuery]. Data is accumulated into session state
///   and delivered via API (POST) or local storage on session end.
///
/// Example usage:
/// ```dart
/// final sleepManager = SleepDataManager();
///
/// // One-shot fetch
/// final response = await sleepManager.getSleepData();
///
/// // Start monitoring (auto-starts on next launch if API is configured)
/// await sleepManager.startMonitoring();
///
/// // Retrieve locally stored sessions (localStorage mode)
/// final sessions = await sleepManager.getLocalSleepSessions();
///
/// // Later, stop monitoring
/// await sleepManager.stopMonitoring();
/// ```
class SleepDataManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/sleep',
  );

  // Note: there is intentionally no EventChannel / stream for sleep payload
  // updates. Background HKObserverQuery delivery fires while Flutter is
  // suspended, so an EventChannel event would be lost. Instead, the host-app
  // Runner (HealthQueueObserver) watches UserDefaults via KVO and handles
  // background payloads natively. Flutter drains getLocalSleepSessions() on
  // AppLifecycleState.resumed (see SleepDataScreen).

  /// Fetches sleep data from HealthKit for the specified time range.
  ///
  /// **Parameters:**
  /// - [startDate]: Start of the time range (defaults to 24 hours ago)
  /// - [endDate]: End of the time range (defaults to now)
  ///
  /// Returns a [SleepDataResponse] containing all sleep samples and aggregated statistics.
  Future<SleepDataResponse> getSleepData({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final effectiveEndDate = endDate ?? DateTime.now();
    final effectiveStartDate =
        startDate ?? effectiveEndDate.subtract(const Duration(hours: 24));

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getSleepData', {
            'startDate': effectiveStartDate.toIso8601String(),
            'endDate': effectiveEndDate.toIso8601String(),
          });

      if (result != null) {
        final map = Map<String, dynamic>.from(result);
        return SleepDataResponse.fromMap(map);
      }

      return _emptyResponse(effectiveStartDate, effectiveEndDate);
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Unknown error fetching sleep data',
        details: e.details,
      );
    }
  }

  /// Starts monitoring sleep data changes.
  ///
  /// In **foreground**: Uses HKAnchoredObjectQueryDescriptor to accumulate
  /// samples into session state.
  ///
  /// In **background**: Uses HKObserverQuery to detect changes and accumulates
  /// samples into session state.
  ///
  /// When the session ends, the finalized session JSON is stored locally;
  /// retrieve with [getLocalSleepSessions] and upload from your app.
  Future<Map<String, dynamic>> startMonitoring({DateTime? startDate}) async {
    final effectiveStartDate =
        startDate ?? DateTime.now().subtract(const Duration(hours: 24));

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'startSleepMonitoring',
        {'startDate': effectiveStartDate.toIso8601String()},
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to start sleep monitoring',
        details: e.details,
      );
    }
  }

  /// Stops monitoring sleep data changes.
  Future<Map<String, dynamic>> stopMonitoring() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'stopSleepMonitoring',
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to stop sleep monitoring',
        details: e.details,
      );
    }
  }

  /// Fetches sleep data that was stored in UserDefaults during background monitoring.
  ///
  /// Returns a [SleepDataResponse] with data collected while the app was in background.
  /// The response includes `storedAt` timestamp indicating when data was last updated.
  Future<SleepDataResponse> fetchStoredSleepData() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'fetchStoredSleepData',
      );

      if (result != null) {
        final map = Map<String, dynamic>.from(result);
        if (map['hasData'] == true) {
          return SleepDataResponse.fromMap(map);
        }
      }

      return _emptyResponse(
        DateTime.now().subtract(const Duration(hours: 24)),
        DateTime.now(),
      );
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to fetch stored sleep data',
        details: e.details,
      );
    }
  }

  /// Clears sleep data stored in UserDefaults.
  Future<void> clearStoredSleepData() async {
    try {
      await _channel.invokeMethod('clearStoredSleepData');
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to clear stored sleep data',
        details: e.details,
      );
    }
  }

  /// Notifies iOS that the app has entered foreground (manual override).
  ///
  /// **Note:** This is typically NOT needed as native iOS handles lifecycle
  /// automatically via `AppLifecycleManager`. Use this only for manual override.
  ///
  /// Switches from background observer to live streaming if monitoring is active.
  Future<void> enterForeground() async {
    try {
      await _channel.invokeMethod('enterSleepForeground');
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to enter foreground mode',
        details: e.details,
      );
    }
  }

  /// Notifies iOS that the app has entered background (manual override).
  ///
  /// **Note:** This is typically NOT needed as native iOS handles lifecycle
  /// automatically via `AppLifecycleManager`. Use this only for manual override.
  ///
  /// Switches from live streaming to background observer if monitoring is active.
  Future<void> enterBackground() async {
    try {
      await _channel.invokeMethod('enterSleepBackground');
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to enter background mode',
        details: e.details,
      );
    }
  }

  /// Arms native sleep session delivery: finalized sessions are stored in
  /// UserDefaults for [getLocalSleepSessions]. The plugin does not HTTP POST.
  ///
  /// Call after login (with [UserSessionManager]) so auto-start can resume.
  ///
  /// ```dart
  /// await sleepManager.configureSleepBackgroundDelivery(
  ///   const SleepBackgroundDeliveryConfig(),
  /// );
  /// ```
  Future<Map<String, dynamic>> configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig config,
  ) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'configureSleepBackgroundDelivery',
        config.toJson(),
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to configure sleep background delivery',
        details: e.details,
      );
    }
  }

  /// Retrieves and clears locally stored sleep sessions.
  ///
  /// Returns and clears locally-stored pending sessions
  /// (`com.humango.health.sleepPendingLocal`) — sessions that have NOT yet been
  /// uploaded to the backend by the native layer.
  ///
  /// When in `localStorage` mode and the app was in background,
  /// finalized sleep sessions are stored locally. Call this method
  /// after the app becomes active to retrieve them.
  ///
  /// Returns a list of JSON strings, each representing a finalized sleep session.
  /// The local storage is cleared after retrieval.
  Future<List<String>> getLocalSleepSessions() async {
    try {
      final result = await _channel.invokeMethod('getLocalSleepSessions');
      if (result is List) {
        return result.cast<String>();
      }
      return [];
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to get local sleep sessions',
        details: e.details,
      );
    }
  }

  /// Calculates a flat aggregated sleep payload from HealthKit samples in the
  /// specified time window, using the group-based session detection algorithm:
  ///
  ///   1. Sort samples by `startDate`
  ///   2. Group consecutive samples with gap ≤ 2 h; discard groups whose
  ///      wall-clock span is < 3 h (naps / noise)
  ///   3. Aggregate surviving groups → flat payload with ceiling-rounded seconds
  ///
  /// Defaults to the current 6 PM → now window when no dates are supplied.
  ///
  /// Throws [SleepDataException] with code `NO_VALID_SLEEP` when no qualifying
  /// groups are found, or `FETCH_ERROR` on a HealthKit failure.
  Future<Map<String, dynamic>> calculateSleepPayload({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final args = <String, String>{};
    if (startDate != null) args['startDate'] = startDate.toIso8601String();
    if (endDate != null) args['endDate'] = endDate.toIso8601String();

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'calculateSleepPayload',
        args.isEmpty ? null : args,
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to calculate sleep payload',
        details: e.details,
      );
    }
  }

  SleepDataResponse _emptyResponse(DateTime from, DateTime to) {
    return SleepDataResponse(
      samples: [],
      sampleCount: 0,
      totalSleepSeconds: 0,
      totalSleepMinutes: 0,
      totalSleepHours: 0,
      stageTotals: SleepStageTotals(
        inBedSeconds: 0,
        asleepUnspecifiedSeconds: 0,
        awakeSeconds: 0,
        asleepCoreSeconds: 0,
        asleepDeepSeconds: 0,
        asleepREMSeconds: 0,
      ),
      fetchedFrom: from,
      fetchedTo: to,
      rawJson: {},
    );
  }
}

/// Exception thrown when sleep data operations fail
class SleepDataException implements Exception {
  final String code;
  final String message;
  final dynamic details;

  SleepDataException({required this.code, required this.message, this.details});

  @override
  String toString() => 'SleepDataException($code): $message';
}
