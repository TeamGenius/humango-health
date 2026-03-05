//
//  sleep_data_manager.dart
//  humango_health
//
//  Dart manager for fetching sleep data from Apple HealthKit
//

import 'package:flutter/services.dart';
import '../models/sleep_sample.dart';

/// Manager for fetching sleep data from Apple HealthKit.
///
/// Provides access to sleep analysis data including sleep stages
/// (inBed, awake, asleepCore, asleepDeep, asleepREM) for a configurable time range.
///
/// Example usage:
/// ```dart
/// final sleepManager = SleepDataManager();
///
/// // Fetch last 24 hours (default)
/// final response = await sleepManager.getSleepData();
///
/// // Fetch specific date range
/// final lastWeek = await sleepManager.getSleepData(
///   startDate: DateTime.now().subtract(const Duration(days: 7)),
///   endDate: DateTime.now(),
/// );
///
/// print('Total sleep: ${response.totalSleepHours} hours');
/// for (final sample in response.samples) {
///   print('${sample.sleepStage}: ${sample.durationMinutes} min');
/// }
/// ```
class SleepDataManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/sleep',
  );

  /// Fetches sleep data from HealthKit for the specified time range.
  ///
  /// **Parameters:**
  /// - [startDate]: Start of the time range (defaults to 24 hours ago)
  /// - [endDate]: End of the time range (defaults to now)
  ///
  /// Returns a [SleepDataResponse] containing:
  /// - `samples`: List of individual [SleepSample] objects
  /// - `totalSleepSeconds/Minutes/Hours`: Aggregated actual sleep time
  /// - `stageTotals`: Time spent in each sleep stage
  /// - `fetchedFrom/To`: The time range of the query
  /// - `rawJson`: The complete raw response from iOS
  ///
  /// **Requirements:**
  /// - iOS 14.0+ (for detailed sleep stages: iOS 16+)
  /// - User must have granted HealthKit read permission for sleepAnalysis
  ///
  /// **Sleep Stages (iOS 16+):**
  /// | Value | Stage | Description |
  /// |-------|-------|-------------|
  /// | 0 | `inBed` | User is in bed but not necessarily asleep |
  /// | 1 | `asleepUnspecified` | User is asleep (stage unknown) |
  /// | 2 | `awake` | User woke up during sleep |
  /// | 3 | `asleepCore` | Core/light sleep |
  /// | 4 | `asleepDeep` | Deep sleep |
  /// | 5 | `asleepREM` | REM sleep |
  ///
  /// Throws an exception if:
  /// - HealthKit is not available on the device
  /// - Sleep data access has been denied
  /// - iOS version is below 14.0
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   // Fetch last 24 hours
  ///   final response = await sleepManager.getSleepData();
  ///
  ///   // Fetch last 7 days
  ///   final weekData = await sleepManager.getSleepData(
  ///     startDate: DateTime.now().subtract(const Duration(days: 7)),
  ///   );
  ///
  ///   // Fetch specific date range
  ///   final rangeData = await sleepManager.getSleepData(
  ///     startDate: DateTime(2026, 3, 1),
  ///     endDate: DateTime(2026, 3, 5),
  ///   );
  ///
  ///   if (response.hasSleepData) {
  ///     print('Sleep duration: ${response.totalSleepHours.toStringAsFixed(1)} hours');
  ///     print('Deep sleep: ${response.stageTotals.asleepDeepMinutes.toStringAsFixed(0)} min');
  ///     print('REM sleep: ${response.stageTotals.asleepREMMinutes.toStringAsFixed(0)} min');
  ///
  ///     // Access raw JSON if needed
  ///     print('Raw response: ${response.rawJson}');
  ///   } else {
  ///     print('No sleep data found for the specified time range');
  ///   }
  /// } catch (e) {
  ///   print('Error fetching sleep data: $e');
  /// }
  /// ```
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

      // Return empty response if no data
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
        fetchedFrom: effectiveStartDate,
        fetchedTo: effectiveEndDate,
        rawJson: {},
      );
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Unknown error fetching sleep data',
        details: e.details,
      );
    }
  }
}

/// Exception thrown when sleep data fetching fails
class SleepDataException implements Exception {
  final String code;
  final String message;
  final dynamic details;

  SleepDataException({required this.code, required this.message, this.details});

  @override
  String toString() => 'SleepDataException($code): $message';
}
