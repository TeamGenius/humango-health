//
//  sleep_data_manager.dart
//  humango_health
//
//  Dart manager for fetching and monitoring sleep data from Apple HealthKit
//  Supports: one-shot fetch, background monitoring (foreground Descriptor + background Observer)
//

import 'package:flutter/services.dart';
import '../models/sleep_sample.dart';

/// Manager for fetching and monitoring sleep data from Apple HealthKit.
///
/// Provides access to sleep analysis data including sleep stages
/// (inBed, awake, asleepCore, asleepDeep, asleepREM).
///
/// Example usage:
/// ```dart
/// final sleepManager = SleepDataManager();
///
/// // One-shot fetch
/// final response = await sleepManager.getSleepData(
///   startDate: DateTime.now().subtract(const Duration(hours: 24)),
/// );
///
/// // Start monitoring (sessions delivered to HumangoHealthDataDelegate)
/// await sleepManager.startMonitoring();
/// await sleepManager.stopMonitoring();
/// ```
class SleepDataManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/sleep',
  );

  // Note: there is intentionally no EventChannel / stream for sleep payload
  // updates. Background HKObserverQuery delivery fires while Flutter is
  // suspended; finalized sessions are delivered directly to
  // HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:) in the
  // host-app iOS Runner.

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
  /// When the session ends, native code calls
  /// `HumangoHealthDataDelegate.onSleepSessionReady(json:sessionId:)` — there is
  /// no Dart stream or local queue to drain for finalized sessions.
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
  Future<void> stopMonitoring() async {
    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('stopSleepMonitoring');
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to stop sleep monitoring',
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
