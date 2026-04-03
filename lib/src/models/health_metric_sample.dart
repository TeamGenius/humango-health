//
//  health_metric_sample.dart
//  humango_health
//
//  Models for HealthKit quantity-type metrics:
//  HRV, heart rate, resting heart rate, body fat %, weight (bodyMass), height
//

/// Supported health metric types that map to HKQuantityTypeIdentifiers.
enum HealthMetricType {
  heartRateVariabilitySDNN,
  restingHeartRate,
  bodyFatPercentage,
  bodyMass,
  height;

  /// The key sent to the iOS native layer.
  String get key => name;

  /// Human-readable display name.
  String get displayName {
    switch (this) {
      case HealthMetricType.heartRateVariabilitySDNN:
        return 'HRV (SDNN)';
      case HealthMetricType.restingHeartRate:
        return 'Resting Heart Rate';
      case HealthMetricType.bodyFatPercentage:
        return 'Body Fat %';
      case HealthMetricType.bodyMass:
        return 'Weight';
      case HealthMetricType.height:
        return 'Height';
    }
  }

  /// Default unit label returned from HealthKit.
  String get defaultUnit {
    switch (this) {
      case HealthMetricType.heartRateVariabilitySDNN:
        return 'ms';
      case HealthMetricType.restingHeartRate:
        return 'bpm';
      case HealthMetricType.bodyFatPercentage:
        return '%';
      case HealthMetricType.bodyMass:
        return 'kg';
      case HealthMetricType.height:
        return 'cm';
    }
  }

  static HealthMetricType? fromKey(String key) {
    for (final type in HealthMetricType.values) {
      if (type.key == key) return type;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Single sample
// ---------------------------------------------------------------------------

/// A single quantity sample from HealthKit (e.g. one HRV reading).
class HealthMetricSample {
  final String uuid;
  final double value;
  final String unit;
  final DateTime startDate;
  final DateTime endDate;
  final String? sourceName;
  final String? sourceBundle;
  final HealthMetricDevice? device;
  final Map<String, dynamic>? metadata;
  final Map<String, dynamic> rawJson;

  HealthMetricSample({
    required this.uuid,
    required this.value,
    required this.unit,
    required this.startDate,
    required this.endDate,
    this.sourceName,
    this.sourceBundle,
    this.device,
    this.metadata,
    required this.rawJson,
  });

  factory HealthMetricSample.fromMap(Map<String, dynamic> map) {
    return HealthMetricSample(
      uuid: map['uuid'] as String? ?? '',
      value: (map['value'] as num?)?.toDouble() ?? 0.0,
      unit: map['unit'] as String? ?? '',
      startDate: DateTime.parse(map['startDate'] as String),
      endDate: DateTime.parse(map['endDate'] as String),
      sourceName: map['sourceName'] as String?,
      sourceBundle: map['sourceBundle'] as String?,
      device: map['device'] != null
          ? HealthMetricDevice.fromMap(
              Map<String, dynamic>.from(map['device'] as Map),
            )
          : null,
      metadata: map['metadata'] != null
          ? Map<String, dynamic>.from(map['metadata'] as Map)
          : null,
      rawJson: Map<String, dynamic>.from(map),
    );
  }

  Map<String, dynamic> toJson() => {
    'uuid': uuid,
    'value': value,
    'unit': unit,
    'startDate': startDate.toIso8601String(),
    'endDate': endDate.toIso8601String(),
    if (sourceName != null) 'sourceName': sourceName,
    if (sourceBundle != null) 'sourceBundle': sourceBundle,
    if (device != null) 'device': device!.toJson(),
    if (metadata != null) 'metadata': metadata,
    'rawJson': rawJson,
  };

  @override
  String toString() => 'HealthMetricSample($value $unit, $startDate)';
}

// ---------------------------------------------------------------------------
// Device info (shared with SleepDevice – kept separate to avoid tight coupling)
// ---------------------------------------------------------------------------

class HealthMetricDevice {
  final String? name;
  final String? model;
  final String? manufacturer;
  final String? hardwareVersion;
  final String? softwareVersion;
  final String? localIdentifier;

  HealthMetricDevice({
    this.name,
    this.model,
    this.manufacturer,
    this.hardwareVersion,
    this.softwareVersion,
    this.localIdentifier,
  });

  factory HealthMetricDevice.fromMap(Map<String, dynamic> map) {
    return HealthMetricDevice(
      name: map['name'] as String?,
      model: map['model'] as String?,
      manufacturer: map['manufacturer'] as String?,
      hardwareVersion: map['hardwareVersion'] as String?,
      softwareVersion: map['softwareVersion'] as String?,
      localIdentifier: map['localIdentifier'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    if (name != null) 'name': name,
    if (model != null) 'model': model,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (hardwareVersion != null) 'hardwareVersion': hardwareVersion,
    if (softwareVersion != null) 'softwareVersion': softwareVersion,
    if (localIdentifier != null) 'localIdentifier': localIdentifier,
  };
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

class HealthMetricStatistics {
  final double average;
  final double min;
  final double max;
  final double sum;

  HealthMetricStatistics({
    required this.average,
    required this.min,
    required this.max,
    required this.sum,
  });

  factory HealthMetricStatistics.fromMap(Map<String, dynamic> map) {
    return HealthMetricStatistics(
      average: (map['average'] as num?)?.toDouble() ?? 0.0,
      min: (map['min'] as num?)?.toDouble() ?? 0.0,
      max: (map['max'] as num?)?.toDouble() ?? 0.0,
      sum: (map['sum'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'average': average,
    'min': min,
    'max': max,
    'sum': sum,
  };

  @override
  String toString() =>
      'HealthMetricStatistics(avg: $average, min: $min, max: $max)';
}

// ---------------------------------------------------------------------------
// Response for a single metric type
// ---------------------------------------------------------------------------

/// Response returned from [HealthMetricsManager.getMetric] or
/// [HealthMetricsManager.getLatestMetric].
class HealthMetricResponse {
  final String metricType;
  final String unit;
  final List<HealthMetricSample> samples;
  final int sampleCount;
  final HealthMetricSample? latestSample;
  final HealthMetricStatistics statistics;
  final DateTime fetchedFrom;
  final DateTime fetchedTo;
  final Map<String, dynamic> rawJson;

  HealthMetricResponse({
    required this.metricType,
    required this.unit,
    required this.samples,
    required this.sampleCount,
    this.latestSample,
    required this.statistics,
    required this.fetchedFrom,
    required this.fetchedTo,
    required this.rawJson,
  });

  factory HealthMetricResponse.fromMap(Map<String, dynamic> map) {
    final samplesRaw = map['samples'] as List<dynamic>? ?? [];
    final samples = samplesRaw
        .map((s) => HealthMetricSample.fromMap(Map<String, dynamic>.from(s)))
        .toList();

    HealthMetricSample? latest;
    if (map['latestSample'] != null) {
      latest = HealthMetricSample.fromMap(
        Map<String, dynamic>.from(map['latestSample'] as Map),
      );
    }

    return HealthMetricResponse(
      metricType: map['metricType'] as String? ?? '',
      unit: map['unit'] as String? ?? '',
      samples: samples,
      sampleCount: map['sampleCount'] as int? ?? samples.length,
      latestSample: latest,
      statistics: HealthMetricStatistics.fromMap(
        Map<String, dynamic>.from(map['statistics'] as Map? ?? {}),
      ),
      fetchedFrom: DateTime.parse(map['fetchedFrom'] as String),
      fetchedTo: DateTime.parse(map['fetchedTo'] as String),
      rawJson: Map<String, dynamic>.from(map),
    );
  }

  bool get hasData => samples.isNotEmpty;

  /// Convenience – latest value or 0.
  double get latestValue => latestSample?.value ?? 0.0;

  @override
  String toString() =>
      'HealthMetricResponse($metricType, $sampleCount samples, latest: $latestValue $unit)';
}

// ---------------------------------------------------------------------------
// Combined response (all metrics at once)
// ---------------------------------------------------------------------------

/// Response from [HealthMetricsManager.getAllMetrics] – one entry per metric type.
class AllHealthMetricsResponse {
  final Map<String, HealthMetricResponse> metrics;
  final Map<String, String> errors;
  final DateTime fetchedFrom;
  final DateTime fetchedTo;

  AllHealthMetricsResponse({
    required this.metrics,
    required this.errors,
    required this.fetchedFrom,
    required this.fetchedTo,
  });

  factory AllHealthMetricsResponse.fromMap(Map<String, dynamic> map) {
    final metricsRaw = map['metrics'] as Map? ?? {};
    final metrics = <String, HealthMetricResponse>{};
    for (final entry in metricsRaw.entries) {
      final key = entry.key as String;
      final value = Map<String, dynamic>.from(entry.value as Map);
      metrics[key] = HealthMetricResponse.fromMap(value);
    }

    final errorsRaw = map['errors'] as Map? ?? {};
    final errors = <String, String>{};
    for (final entry in errorsRaw.entries) {
      errors[entry.key as String] = entry.value as String;
    }

    return AllHealthMetricsResponse(
      metrics: metrics,
      errors: errors,
      fetchedFrom: DateTime.parse(map['fetchedFrom'] as String),
      fetchedTo: DateTime.parse(map['fetchedTo'] as String),
    );
  }

  /// Quick access helpers
  HealthMetricResponse? get hrv => metrics['heartRateVariabilitySDNN'];
  HealthMetricResponse? get restingHeartRate => metrics['restingHeartRate'];
  HealthMetricResponse? get bodyFatPercentage => metrics['bodyFatPercentage'];
  HealthMetricResponse? get weight => metrics['bodyMass'];
  HealthMetricResponse? get height => metrics['height'];

  @override
  String toString() =>
      'AllHealthMetricsResponse(${metrics.length} metrics, ${errors.length} errors)';
}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

class HealthMetricsException implements Exception {
  final String code;
  final String message;
  final dynamic details;

  HealthMetricsException({
    required this.code,
    required this.message,
    this.details,
  });

  @override
  String toString() => 'HealthMetricsException($code): $message';
}
