import 'quantity_series.dart';

class WorkoutData {
  final String workoutId;
  final String activityType;
  final DateTime startTime;
  final DateTime endTime;
  final double duration;
  final double? distance;
  final double? activeCalories;
  final WorkoutStatistics statistics;
  final List<QuantitySeries> quantitySeries;
  final List<RouteLocation> route;
  final List<WorkoutEvent> events;
  final Map<String, dynamic> metadata;

  /// Non-null for multisport workouts (e.g. Triathlon).
  /// Each element represents a sub-activity session (Run, Transition, Bike, etc.).
  final List<WorkoutSession>? sessions;

  /// Convenience getter — `true` when this is a multisport workout with sessions.
  bool get isMultisport => sessions != null && sessions!.isNotEmpty;

  WorkoutData({
    required this.workoutId,
    required this.activityType,
    required this.startTime,
    required this.endTime,
    required this.duration,
    this.distance,
    this.activeCalories,
    required this.statistics,
    required this.quantitySeries,
    required this.route,
    required this.events,
    required this.metadata,
    this.sessions,
  });

  factory WorkoutData.fromJson(Map<String, dynamic> json) {
    // Parse sessions for multisport workouts
    final List<WorkoutSession>? sessions;
    if (json['sessions'] is List && (json['sessions'] as List).isNotEmpty) {
      sessions = (json['sessions'] as List<dynamic>)
          .map((e) => WorkoutSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } else {
      sessions = null;
    }

    // For multisport: series_data lives inside each session; top-level has none.
    // For single-sport: series_data is at the top level.
    final seriesDataSource = json['series_data'] ?? json['routeData'];

    return WorkoutData(
      workoutId: json['device_activity_id'] ?? json['deviceActivityId'] ?? '',
      activityType: json['sport'] ?? '',
      startTime: DateTime.parse(
        json['start_time'] ?? DateTime.now().toIso8601String(),
      ),
      endTime: json['end_time'] != null
          ? DateTime.parse(json['end_time'])
          : DateTime.now(),
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      distance: (json['distance'] as num?)?.toDouble(),
      activeCalories: _extractActiveCalories(json['statistics']),
      statistics: WorkoutStatistics.fromJson(json['statistics']),
      quantitySeries:
          (seriesDataSource?['samples'] as List<dynamic>?)
              ?.map((e) => QuantitySeries.fromSamplesJson(e))
              .toList() ??
          [],
      route:
          (seriesDataSource?['locations'] as List<dynamic>?)
              ?.map((e) => RouteLocation.fromJson(e))
              .toList() ??
          [],
      events:
          (json['events'] as List<dynamic>?)
              ?.map((e) => WorkoutEvent.fromJson(e))
              .toList() ??
          [],
      metadata: json['metadata'] ?? {},
      sessions: sessions,
    );
  }

  /// Safely extract active calories from the statistics field.
  /// iOS sends statistics as a List<Map<String,double>> — not a nested map.
  static double? _extractActiveCalories(dynamic raw) {
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          final val = entry['HKQuantityTypeIdentifierActiveEnergyBurned'];
          if (val is num) return val.toDouble();
        }
      }
    } else if (raw is Map) {
      final v = raw['activeEnergy']?['sum'];
      if (v is num) return v.toDouble();
    }
    return null;
  }
}

/// Represents a single sub-activity session within a multisport workout.
class WorkoutSession {
  final String sessionId;
  final String deviceActivityId;
  final String sport;
  final DateTime startTime;
  final DateTime endTime;
  final double duration;
  final double distance;
  final String type;
  final WorkoutStatistics statistics;
  final List<QuantitySeries> quantitySeries;
  final List<RouteLocation> route;
  final List<WorkoutEvent> events;
  final Map<String, dynamic> metadata;

  WorkoutSession({
    required this.sessionId,
    required this.deviceActivityId,
    required this.sport,
    required this.startTime,
    required this.endTime,
    required this.duration,
    required this.distance,
    required this.type,
    required this.statistics,
    required this.quantitySeries,
    required this.route,
    required this.events,
    required this.metadata,
  });

  factory WorkoutSession.fromJson(Map<String, dynamic> json) {
    final seriesData = json['series_data'];
    return WorkoutSession(
      sessionId: json['session_id'] ?? '',
      deviceActivityId: json['device_activity_id'] ?? '',
      sport: json['sport'] ?? '',
      startTime: DateTime.parse(
        json['start_time'] ?? DateTime.now().toIso8601String(),
      ),
      endTime: DateTime.parse(
        json['end_time'] ?? DateTime.now().toIso8601String(),
      ),
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      distance: (json['distance'] as num?)?.toDouble() ?? 0.0,
      type: json['type'] ?? 'session',
      statistics: WorkoutStatistics.fromJson(json['statistics']),
      quantitySeries:
          (seriesData?['samples'] as List<dynamic>?)
              ?.map((e) => QuantitySeries.fromSamplesJson(e))
              .toList() ??
          [],
      route:
          (seriesData?['locations'] as List<dynamic>?)
              ?.map((e) => RouteLocation.fromJson(e))
              .toList() ??
          [],
      events:
          (json['events'] as List<dynamic>?)
              ?.map((e) => WorkoutEvent.fromJson(e))
              .toList() ??
          [],
      metadata: json['metadata'] ?? {},
    );
  }
}

class WorkoutStatistics {
  final double? avgHeartRate;
  final double? maxHeartRate;
  final double? avgPower;
  final double? avgCadence;

  WorkoutStatistics({
    this.avgHeartRate,
    this.maxHeartRate,
    this.avgPower,
    this.avgCadence,
  });

  /// Parses statistics from the iOS payload.
  /// iOS sends statistics as a List<Map<String, double>> e.g.
  /// [{"HKQuantityTypeIdentifierHeartRate": 72.5}, ...].
  /// Accepts both List and Map formats for backwards compatibility.
  factory WorkoutStatistics.fromJson(dynamic raw) {
    final Map<String, double> flat = {};

    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map) {
          for (final kv in entry.entries) {
            if (kv.value is num) {
              flat[kv.key.toString()] = (kv.value as num).toDouble();
            }
          }
        }
      }
    } else if (raw is Map) {
      // Legacy / alternative format: nested map
      final map = raw.cast<String, dynamic>();
      return WorkoutStatistics(
        avgHeartRate: (map['heartRate']?['average'] as num?)?.toDouble(),
        maxHeartRate: (map['heartRate']?['maximum'] as num?)?.toDouble(),
        avgPower:
            (map['cyclingPower']?['average'] as num?)?.toDouble() ??
            (map['runningPower']?['average'] as num?)?.toDouble(),
        avgCadence: (map['cyclingCadence']?['average'] as num?)?.toDouble(),
      );
    }

    return WorkoutStatistics(
      avgHeartRate: flat['HKQuantityTypeIdentifierHeartRate'],
      maxHeartRate: null,
      avgPower:
          flat['HKQuantityTypeIdentifierCyclingPower'] ??
          flat['HKQuantityTypeIdentifierRunningPower'],
      avgCadence: flat['HKQuantityTypeIdentifierCyclingCadence'],
    );
  }
}

class RouteLocation {
  final double latitude;
  final double longitude;
  final double altitude;
  final double? speed;
  final double? course;
  final DateTime timestamp;

  RouteLocation({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    this.speed,
    this.course,
    required this.timestamp,
  });

  factory RouteLocation.fromJson(Map<String, dynamic> json) {
    return RouteLocation(
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
      altitude: (json['altitude'] as num?)?.toDouble() ?? 0.0,
      speed: (json['speed'] as num?)?.toDouble(),
      course: (json['course'] as num?)?.toDouble(),
      timestamp: DateTime.parse(
        json['timestamp'] ?? DateTime.now().toIso8601String(),
      ),
    );
  }
}

class WorkoutEvent {
  final String type;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  WorkoutEvent({required this.type, required this.timestamp, this.metadata});

  factory WorkoutEvent.fromJson(Map<String, dynamic> json) {
    return WorkoutEvent(
      type: json['type'] ?? '',
      timestamp: DateTime.parse(
        json['timestamp'] ?? DateTime.now().toIso8601String(),
      ),
      metadata: json['metadata'],
    );
  }
}
