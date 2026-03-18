//
//  health_metrics_manager.dart
//  humango_health
//
//  Dart manager for reading health quantity metrics from Apple HealthKit.
//  Supports: HRV, resting heart rate, body fat %, weight (bodyMass), height
//  Supports automatic HRV updates in foreground, background, and when app is suspended.
//

import 'dart:async';
import 'package:flutter/services.dart';
import '../models/health_metric_sample.dart';

/// Manager for fetching health quantity metrics from Apple HealthKit.
///
/// Provides typed access to:
/// - **HRV** (heartRateVariabilitySDNN) – standard deviation of heartbeat intervals in ms
/// - **Resting Heart Rate** – estimated lowest resting HR in bpm
/// - **Body Fat %** – body fat percentage (0-1 from HealthKit, displayed as %)
/// - **Weight** (bodyMass) – in kg
/// - **Height** – in cm
///
/// HRV auto-read: Call [startHRVMonitoring] to observe HealthKit for new HRV data.
/// Updates are delivered via [hrvUpdates] stream when in foreground, or via
/// [getPendingHRVUpdates] after returning from background/suspended.
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
/// // Auto-read HRV when Health app (or any source) writes new data
/// await metricsManager.startHRVMonitoring();
/// metricsManager.hrvUpdates.listen((update) {
///   print('New HRV: ${update['samples']}');
/// });
/// ```
class HealthMetricsManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/metrics',
  );

  static const EventChannel _hrvEventChannel = EventChannel(
    'com.humango.health/metrics/hrv_updates',
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
  }) => getMetric(
    HealthMetricType.heartRateVariabilitySDNN,
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

  /// Stream of HRV updates when new data is written to HealthKit.
  /// Only emits while the app is in foreground and [startHRVMonitoring] is active.
  /// When the app was in background/suspended, use [getPendingHRVUpdates] after
  /// resuming to get updates that were collected while away.
  Stream<Map<String, dynamic>> get hrvUpdates =>
      _hrvEventChannel.receiveBroadcastStream().cast<Map<dynamic, dynamic>>().map(
            (m) => Map<String, dynamic>.from(m),
          );

  /// Start observing HealthKit for new HRV data. Works in foreground, background,
  /// and when app is suspended (iOS wakes the app briefly when new HRV is saved).
  /// Call once after user logs in; persists across app launches when user stays logged in.
  Future<void> startHRVMonitoring() async {
    await _channel.invokeMethod('startHRVMonitoring');
  }

  /// Stop HRV observation and background delivery.
  Future<void> stopHRVMonitoring() async {
    await _channel.invokeMethod('stopHRVMonitoring');
  }

  /// Returns HRV updates that were collected while the app was in background or
  /// suspended. Each element has the same shape as a single [getMetric] response
  /// (metricType, unit, samples, sampleCount, fetchedAt). Clears the pending list.
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
