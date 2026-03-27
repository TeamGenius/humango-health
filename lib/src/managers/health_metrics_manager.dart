//
//  health_metrics_manager.dart
//  humango_health
//
//  Dart manager for reading health quantity metrics from Apple HealthKit.
//  Supports: HRV, resting heart rate, body fat %, weight (bodyMass), height
//  Monitoring is handled natively via HKAnchoredObjectQueryDescriptor (foreground)
//  and HKObserverQuery (background); delivery is through HumangoHealthDataDelegate.
//

import 'package:flutter/services.dart';
import '../models/health_metric_sample.dart';

/// Manager for fetching health quantity metrics from Apple HealthKit.
///
/// Provides typed access to:
/// - **HRV** (heartRateVariabilitySDNN) – standard deviation of heartbeat intervals in ms
/// - **Heart Rate** – beat-to-beat / timed HR samples in bpm
/// - **Resting Heart Rate** – estimated lowest resting HR in bpm
/// - **Body Fat %** – body fat percentage (0-1 from HealthKit, displayed as %)
/// - **Weight** (bodyMass) – in kg
/// - **Height** – in cm
///
/// Quantity metrics auto-read: Call [startHRVMonitoring] to observe HealthKit for new
/// samples (HRV, heart rate, resting HR, body fat, weight, height).
/// Foreground uses `HKAnchoredObjectQueryDescriptor`; background uses `HKObserverQuery`.
/// All batches are delivered to `HumangoHealthDataDelegate.onHealthMetricSamplesReady`
/// on iOS — there is no Dart stream. [getPendingHRVUpdates] always returns an empty list.
///
/// Example usage:
/// ```dart
/// final metricsManager = HealthMetricsManager();
///
/// // Fetch HRV samples from the last 7 days
/// final hrvResponse = await metricsManager.getMetric(
///   HealthMetricType.heartRateVariabilitySDNN,
///   startDate: DateTime.now().subtract(const Duration(days: 7)),
/// );
/// print('Average HRV: ${hrvResponse.statistics.average} ms');
///
/// // Start observing — new data is pushed to HumangoHealthDataDelegate on iOS
/// await metricsManager.startHRVMonitoring();
/// ```
class HealthMetricsManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/metrics',
  );

  // ---------------------------------------------------------------------------
  // Single metric fetch
  // ---------------------------------------------------------------------------

  /// Fetch samples for a specific [metricType] within a date range.
  ///
  /// Defaults to last 30 days if [startDate] / [endDate] are omitted.
  /// Pass [limit] to cap the number of returned samples.
  Future<HealthMetricResponse> getMetric(
    HealthMetricType metricType, {
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) async {
    final effectiveEndDate = endDate ?? DateTime.now();
    final effectiveStartDate =
        startDate ?? effectiveEndDate.subtract(const Duration(days: 30));

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getHealthMetric', {
            'metricType': metricType.key,
            'startDate': effectiveStartDate.toUtc().toIso8601String(),
            'endDate': effectiveEndDate.toUtc().toIso8601String(),
            if (limit != null) 'limit': limit,
          });

      if (result != null) {
        return HealthMetricResponse.fromMap(Map<String, dynamic>.from(result));
      }

      return _emptyResponse(
        metricType.key,
        metricType.defaultUnit,
        effectiveStartDate,
        effectiveEndDate,
      );
    } on PlatformException catch (e) {
      throw HealthMetricsException(
        code: e.code,
        message: e.message ?? 'Error fetching ${metricType.displayName}',
        details: e.details,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Latest sample shorthand
  // ---------------------------------------------------------------------------

  /// Fetch only the most recent sample for a [metricType].
  ///
  /// Searches across all time – returns the single newest sample.
  Future<HealthMetricResponse> getLatestMetric(
    HealthMetricType metricType,
  ) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getLatestHealthMetric',
        {'metricType': metricType.key},
      );

      if (result != null) {
        return HealthMetricResponse.fromMap(Map<String, dynamic>.from(result));
      }

      return _emptyResponse(
        metricType.key,
        metricType.defaultUnit,
        DateTime.now(),
        DateTime.now(),
      );
    } on PlatformException catch (e) {
      throw HealthMetricsException(
        code: e.code,
        message: e.message ?? 'Error fetching latest ${metricType.displayName}',
        details: e.details,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // All metrics at once
  // ---------------------------------------------------------------------------

  /// Fetch all supported metrics in a single call.
  ///
  /// Defaults to last 30 days. Errors for individual types are collected in
  /// [AllHealthMetricsResponse.errors] rather than throwing.
  Future<AllHealthMetricsResponse> getAllMetrics({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final effectiveEndDate = endDate ?? DateTime.now();
    final effectiveStartDate =
        startDate ?? effectiveEndDate.subtract(const Duration(days: 30));

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getAllHealthMetrics', {
            'startDate': effectiveStartDate.toUtc().toIso8601String(),
            'endDate': effectiveEndDate.toUtc().toIso8601String(),
          });

      if (result != null) {
        return AllHealthMetricsResponse.fromMap(
          Map<String, dynamic>.from(result),
        );
      }

      return AllHealthMetricsResponse(
        metrics: {},
        errors: {},
        fetchedFrom: effectiveStartDate,
        fetchedTo: effectiveEndDate,
      );
    } on PlatformException catch (e) {
      throw HealthMetricsException(
        code: e.code,
        message: e.message ?? 'Error fetching all health metrics',
        details: e.details,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Convenience methods for each metric type
  // ---------------------------------------------------------------------------

  /// Fetch HRV (Heart Rate Variability SDNN) samples.
  Future<HealthMetricResponse> getHRV({
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }  ) => getMetric(
    HealthMetricType.heartRateVariabilitySDNN,
    startDate: startDate,
    endDate: endDate,
    limit: limit,
  );

  /// Fetch heart rate samples (not the same as resting heart rate).
  Future<HealthMetricResponse> getHeartRate({
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) => getMetric(
    HealthMetricType.heartRate,
    startDate: startDate,
    endDate: endDate,
    limit: limit,
  );

  /// Fetch resting heart rate samples.
  Future<HealthMetricResponse> getRestingHeartRate({
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) => getMetric(
    HealthMetricType.restingHeartRate,
    startDate: startDate,
    endDate: endDate,
    limit: limit,
  );

  /// Fetch body fat percentage samples.
  Future<HealthMetricResponse> getBodyFatPercentage({
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) => getMetric(
    HealthMetricType.bodyFatPercentage,
    startDate: startDate,
    endDate: endDate,
    limit: limit,
  );

  /// Fetch weight (body mass) samples.
  Future<HealthMetricResponse> getWeight({
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) => getMetric(
    HealthMetricType.bodyMass,
    startDate: startDate,
    endDate: endDate,
    limit: limit,
  );

  /// Fetch height samples.
  Future<HealthMetricResponse> getHeight({
    DateTime? startDate,
    DateTime? endDate,
    int? limit,
  }) => getMetric(
    HealthMetricType.height,
    startDate: startDate,
    endDate: endDate,
    limit: limit,
  );

  // ---------------------------------------------------------------------------
  // HRV automatic updates (background / suspended)
  // ---------------------------------------------------------------------------

  /// Start observing HealthKit for quantity vitals and body metrics (HRV, heart rate,
  /// resting HR, body fat, weight, height).
  /// Foreground: uses `HKAnchoredObjectQueryDescriptor` (anchor-based streaming).
  /// Background / suspended: uses `HKObserverQuery` with background delivery.
  /// All batches are delivered to `HumangoHealthDataDelegate.onHealthMetricSamplesReady`
  /// on iOS — there is no Flutter stream. Call once after login; persists across launches.
  Future<void> startHRVMonitoring() async {
    await _channel.invokeMethod('startHRVMonitoring');
  }

  /// Stop quantity-metric observation and background delivery for all observed types.
  Future<void> stopHRVMonitoring() async {
    await _channel.invokeMethod('stopHRVMonitoring');
  }

  /// Legacy hook: always `[]`. Background metric batches are delivered to
  /// `HumangoHealthDataDelegate.onHealthMetricSamplesReady` on iOS, not queued here.
  Future<List<Map<String, dynamic>>> getPendingHRVUpdates() async {
    final result = await _channel.invokeMethod<List<dynamic>>('getPendingHRVUpdates');
    if (result == null) return [];
    return result
        .map((e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
        .toList();
  }

  /// Whether HRV monitoring is currently enabled (started and not stopped).
  Future<bool> isHRVMonitoringActive() async {
    final result = await _channel.invokeMethod<bool>('isHRVMonitoringActive');
    return result ?? false;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  HealthMetricResponse _emptyResponse(
    String metricType,
    String unit,
    DateTime from,
    DateTime to,
  ) {
    return HealthMetricResponse(
      metricType: metricType,
      unit: unit,
      samples: [],
      sampleCount: 0,
      latestSample: null,
      statistics: HealthMetricStatistics(average: 0, min: 0, max: 0, sum: 0),
      fetchedFrom: from,
      fetchedTo: to,
      rawJson: {},
    );
  }
}
