//
//  health_metrics_manager.dart
//  humango_health
//
//  Dart manager for reading health quantity metrics from Apple HealthKit.
//  Supports: HRV, resting heart rate, body fat %, weight (bodyMass), height.
//
//  Querying is explicit: call fetchHealthMetric with a start and end date.
//  Monitoring is native-iOS-only — use HumangoHealthPlugin.shared on the iOS side.
//  When a monitor fires, the host app receives the payload via
//  HumangoHealthDataDelegate.onHealthMetricReady (native iOS delegate).
//

import 'package:flutter/services.dart';
import '../models/health_metric_sample.dart';

/// Manager for fetching health quantity metrics from Apple HealthKit.
///
/// Provides typed, on-demand access to:
/// - **HRV** (heartRateVariabilitySDNN) – standard deviation of heartbeat intervals in ms
/// - **Resting Heart Rate** – estimated lowest resting HR in bpm
/// - **Body Fat %** – body fat percentage (HealthKit stores 0–1 range, returned as %)
/// - **Weight** (bodyMass) – in kg
/// - **Height** – in cm
///
/// All numeric values use full [double] precision — no rounding is applied at any layer.
///
/// Example:
/// ```dart
/// final manager = HealthMetricsManager();
///
/// // Fetch HRV for the last 7 days
/// final response = await manager.fetchHealthMetric(
///   HealthMetricType.heartRateVariabilitySDNN,
///   startDate: DateTime.now().subtract(const Duration(days: 7)),
///   endDate: DateTime.now(),
/// );
/// print('Latest HRV: \${response.latestValue} ms');
/// ```
class HealthMetricsManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/metrics',
  );

  // ---------------------------------------------------------------------------
  // On-demand fetch
  // ---------------------------------------------------------------------------

  /// Fetch all samples for [metricType] within the given date range.
  ///
  /// [startDate] and [endDate] default to the last 30 days when omitted.
  /// Dates are transmitted as UTC ISO 8601 strings with fractional seconds.
  /// All numeric values in the returned [HealthMetricResponse] are raw [double]
  /// with full HealthKit precision — no rounding is applied.
  Future<HealthMetricResponse> fetchHealthMetric(
    HealthMetricType metricType, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final effectiveEndDate = endDate ?? DateTime.now();
    final effectiveStartDate =
        startDate ?? effectiveEndDate.subtract(const Duration(days: 30));

    final arguments = <String, dynamic>{
      'metricType': metricType.key,
      'startDate': effectiveStartDate.toUtc().toIso8601String(),
      'endDate': effectiveEndDate.toUtc().toIso8601String(),
    };

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'fetchHealthMetric',
        arguments,
      );

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
  // Monitoring control (triggers native iOS HealthMetricMonitor)
  // ---------------------------------------------------------------------------

  /// Start monitoring [metricType] on the native iOS side.
  ///
  /// Delivery is via `HumangoHealthDataDelegate.onHealthMetricReady`
  /// on the iOS delegate — no Dart-side callback is fired.
  /// The monitor re-fetches current-day samples (midnight → now) on each
  /// HealthKit notification; it is NOT a delta.
  Future<void> startMetricMonitoring(HealthMetricType metricType) async {
    try {
      await _channel.invokeMethod<void>('startMetricMonitoring', {
        'metricType': metricType.key,
      });
    } on PlatformException catch (e) {
      throw HealthMetricsException(
        code: e.code,
        message:
            e.message ??
            'Error starting monitoring for ${metricType.displayName}',
        details: e.details,
      );
    }
  }

  /// Stop monitoring [metricType] on the native iOS side.
  Future<void> stopMetricMonitoring(HealthMetricType metricType) async {
    try {
      await _channel.invokeMethod<void>('stopMetricMonitoring', {
        'metricType': metricType.key,
      });
    } on PlatformException catch (e) {
      throw HealthMetricsException(
        code: e.code,
        message:
            e.message ??
            'Error stopping monitoring for ${metricType.displayName}',
        details: e.details,
      );
    }
  }

  /// Stop all active metric monitors on the native iOS side.
  Future<void> stopAllMetricMonitoring() async {
    try {
      await _channel.invokeMethod<void>('stopAllMetricMonitoring');
    } on PlatformException catch (e) {
      throw HealthMetricsException(
        code: e.code,
        message: e.message ?? 'Error stopping all metric monitors',
        details: e.details,
      );
    }
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
