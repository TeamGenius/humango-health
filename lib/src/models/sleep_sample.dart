//
//  sleep_sample.dart
//  humango_health
//
//  Represents a single sleep sample from Apple HealthKit
//

/// Represents a single sleep sample from Apple HealthKit's sleepAnalysis data.
class SleepSample {
  /// Unique identifier for this sample from HealthKit
  final String uuid;

  /// Start time of this sleep segment
  final DateTime startDate;

  /// End time of this sleep segment
  final DateTime endDate;

  /// Raw integer value from HealthKit (0-5)
  final int value;

  /// Human-readable sleep stage name
  /// - `inBed`: User is in bed but not necessarily asleep
  /// - `asleepUnspecified`: User is asleep (stage unknown)
  /// - `awake`: User woke up during sleep
  /// - `asleepCore`: Core/light sleep (iOS 16+)
  /// - `asleepDeep`: Deep sleep (iOS 16+)
  /// - `asleepREM`: REM sleep (iOS 16+)
  final String sleepStage;

  /// Duration of this sleep segment in seconds
  final double durationSeconds;

  /// Duration of this sleep segment in minutes
  final double durationMinutes;

  /// Name of the source app/device that recorded this data
  final String? sourceName;

  /// Bundle identifier of the source app
  final String? sourceBundle;

  /// Device information (if available)
  final SleepDevice? device;

  /// Additional metadata from HealthKit
  final Map<String, dynamic>? metadata;

  /// The complete raw JSON from HealthKit
  final Map<String, dynamic> rawJson;

  SleepSample({
    required this.uuid,
    required this.startDate,
    required this.endDate,
    required this.value,
    required this.sleepStage,
    required this.durationSeconds,
    required this.durationMinutes,
    this.sourceName,
    this.sourceBundle,
    this.device,
    this.metadata,
    required this.rawJson,
  });

  /// Creates a SleepSample from a HealthKit JSON map
  factory SleepSample.fromMap(Map<String, dynamic> map) {
    return SleepSample(
      uuid: map['uuid'] as String? ?? '',
      startDate: DateTime.parse(map['startDate'] as String),
      endDate: DateTime.parse(map['endDate'] as String),
      value: map['value'] as int? ?? 0,
      sleepStage: map['sleepStage'] as String? ?? 'unknown',
      durationSeconds: (map['durationSeconds'] as num?)?.toDouble() ?? 0.0,
      durationMinutes: (map['durationMinutes'] as num?)?.toDouble() ?? 0.0,
      sourceName: map['sourceName'] as String?,
      sourceBundle: map['sourceBundle'] as String?,
      device: map['device'] != null
          ? SleepDevice.fromMap(Map<String, dynamic>.from(map['device']))
          : null,
      metadata: map['metadata'] != null
          ? Map<String, dynamic>.from(map['metadata'])
          : null,
      rawJson: Map<String, dynamic>.from(map),
    );
  }

  /// Converts this sample to a JSON map
  Map<String, dynamic> toJson() => rawJson;

  /// Check if this is actual sleep (not just in bed or awake)
  bool get isActualSleep =>
      sleepStage != 'inBed' && sleepStage != 'awake' && sleepStage != 'unknown';

  @override
  String toString() =>
      'SleepSample($sleepStage, ${durationMinutes.toStringAsFixed(1)} min)';
}

/// Device information for a sleep sample
class SleepDevice {
  final String? name;
  final String? model;
  final String? manufacturer;
  final String? hardwareVersion;
  final String? softwareVersion;
  final String? localIdentifier;

  SleepDevice({
    this.name,
    this.model,
    this.manufacturer,
    this.hardwareVersion,
    this.softwareVersion,
    this.localIdentifier,
  });

  factory SleepDevice.fromMap(Map<String, dynamic> map) {
    return SleepDevice(
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

/// Aggregated sleep stage totals
class SleepStageTotals {
  final double inBedSeconds;
  final double asleepUnspecifiedSeconds;
  final double awakeSeconds;
  final double asleepCoreSeconds;
  final double asleepDeepSeconds;
  final double asleepREMSeconds;

  SleepStageTotals({
    required this.inBedSeconds,
    required this.asleepUnspecifiedSeconds,
    required this.awakeSeconds,
    required this.asleepCoreSeconds,
    required this.asleepDeepSeconds,
    required this.asleepREMSeconds,
  });

  factory SleepStageTotals.fromMap(Map<String, dynamic> map) {
    double getSeconds(String key) {
      final value = map[key];
      if (value is Map) {
        return (value['seconds'] as num?)?.toDouble() ?? 0.0;
      }
      return 0.0;
    }

    return SleepStageTotals(
      inBedSeconds: getSeconds('inBed'),
      asleepUnspecifiedSeconds: getSeconds('asleepUnspecified'),
      awakeSeconds: getSeconds('awake'),
      asleepCoreSeconds: getSeconds('asleepCore'),
      asleepDeepSeconds: getSeconds('asleepDeep'),
      asleepREMSeconds: getSeconds('asleepREM'),
    );
  }

  /// Total actual sleep time (excluding inBed and awake)
  double get totalSleepSeconds =>
      asleepUnspecifiedSeconds +
      asleepCoreSeconds +
      asleepDeepSeconds +
      asleepREMSeconds;

  double get totalSleepMinutes => totalSleepSeconds / 60.0;
  double get totalSleepHours => totalSleepSeconds / 3600.0;

  double get inBedMinutes => inBedSeconds / 60.0;
  double get awakeMinutes => awakeSeconds / 60.0;
  double get asleepCoreMinutes => asleepCoreSeconds / 60.0;
  double get asleepDeepMinutes => asleepDeepSeconds / 60.0;
  double get asleepREMMinutes => asleepREMSeconds / 60.0;
}

/// Complete sleep data response from HealthKit
class SleepDataResponse {
  /// List of individual sleep samples
  final List<SleepSample> samples;

  /// Number of samples returned
  final int sampleCount;

  /// Total sleep time in seconds (excludes inBed and awake)
  final double totalSleepSeconds;

  /// Total sleep time in minutes
  final double totalSleepMinutes;

  /// Total sleep time in hours
  final double totalSleepHours;

  /// Time spent in each sleep stage
  final SleepStageTotals stageTotals;

  /// Start of the query time range
  final DateTime fetchedFrom;

  /// End of the query time range
  final DateTime fetchedTo;

  /// Raw JSON response from iOS
  final Map<String, dynamic> rawJson;

  SleepDataResponse({
    required this.samples,
    required this.sampleCount,
    required this.totalSleepSeconds,
    required this.totalSleepMinutes,
    required this.totalSleepHours,
    required this.stageTotals,
    required this.fetchedFrom,
    required this.fetchedTo,
    required this.rawJson,
  });

  factory SleepDataResponse.fromMap(Map<String, dynamic> map) {
    final samplesRaw = map['samples'] as List<dynamic>? ?? [];
    final samples = samplesRaw
        .map((s) => SleepSample.fromMap(Map<String, dynamic>.from(s)))
        .toList();

    // iOS sends START_DATE / END_DATE (legacy backend keys) while Dart models
    // originally expected fetchedFrom / fetchedTo. Accept both.
    final fetchedFromStr =
        (map['fetchedFrom'] ?? map['START_DATE']) as String?;
    final fetchedToStr = (map['fetchedTo'] ?? map['END_DATE']) as String?;

    return SleepDataResponse(
      samples: samples,
      sampleCount: map['sampleCount'] as int? ?? samples.length,
      totalSleepSeconds:
          ((map['totalSleepSeconds'] ?? map['TOTAL_SLEEP']) as num?)
                  ?.toDouble() ??
              0.0,
      totalSleepMinutes: (map['totalSleepMinutes'] as num?)?.toDouble() ?? 0.0,
      totalSleepHours: (map['totalSleepHours'] as num?)?.toDouble() ?? 0.0,
      stageTotals: SleepStageTotals.fromMap(
        Map<String, dynamic>.from(map['stageTotals'] ?? {}),
      ),
      fetchedFrom: fetchedFromStr != null
          ? DateTime.parse(fetchedFromStr)
          : DateTime.now().subtract(const Duration(hours: 24)),
      fetchedTo: fetchedToStr != null
          ? DateTime.parse(fetchedToStr)
          : DateTime.now(),
      rawJson: Map<String, dynamic>.from(map),
    );
  }

  /// Converts this response to a JSON map
  Map<String, dynamic> toJson() => rawJson;

  /// Check if any sleep data was found
  bool get hasSleepData => samples.isNotEmpty;

  /// Get only actual sleep samples (excluding inBed and awake)
  List<SleepSample> get actualSleepSamples =>
      samples.where((s) => s.isActualSleep).toList();

  @override
  String toString() =>
      'SleepDataResponse($sampleCount samples, ${totalSleepHours.toStringAsFixed(1)}h sleep)';
}
