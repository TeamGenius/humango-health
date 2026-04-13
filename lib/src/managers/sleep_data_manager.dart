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
/// // One-shot fetch with calculateSleepPayload pipeline applied internally
/// final response = await sleepManager.getSleepData(
///   startDate: DateTime.now().subtract(const Duration(hours: 24)),
/// );
///
/// // Raw samples (no aggregation, no source filter)
/// final samples = await sleepManager.fetchSleepSamples(startDate: ..., endDate: ...);
///
/// // Calculated payload (full pipeline)
/// final payload = await sleepManager.calculateSleepPayload(startDate: ..., endDate: ...);
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
            'startDate': effectiveStartDate.toUtc().toIso8601String(),
            'endDate': effectiveEndDate.toUtc().toIso8601String(),
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

  /// Fetches raw sleep samples from HealthKit for the specified time range
  /// without any aggregation or grouping.
  ///
  /// This is the direct equivalent of calling `fetchSleepSamples(from:to:)` on
  /// the native `SleepDataManager`. Returns every `HKCategorySample` in the
  /// window as a list of [SleepSample] objects.
  ///
  /// **Parameters:**
  /// - [startDate]: Start of the time range (defaults to 24 hours ago)
  /// - [endDate]: End of the time range (defaults to now)
  Future<List<SleepSample>> fetchSleepSamples({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final effectiveEndDate = endDate ?? DateTime.now();
    final effectiveStartDate =
        startDate ?? effectiveEndDate.subtract(const Duration(hours: 24));

    try {
      final result = await _channel
          .invokeMethod<List<dynamic>>('fetchSleepSamples', {
            'startDate': effectiveStartDate.toUtc().toIso8601String(),
            'endDate': effectiveEndDate.toUtc().toIso8601String(),
          });

      if (result == null) return [];
      return result
          .map((e) => SleepSample.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Unknown error fetching sleep samples',
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
    if (startDate != null)
      args['startDate'] = startDate.toUtc().toIso8601String();
    if (endDate != null) args['endDate'] = endDate.toUtc().toIso8601String();

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
