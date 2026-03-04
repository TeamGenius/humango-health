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
  });

  factory WorkoutData.fromJson(Map<String, dynamic> json) {
    return WorkoutData(
      workoutId: json['deviceActivityId'] ?? '',
      activityType: json['sport'] ?? '',
      startTime: DateTime.parse(json['start_time'] ?? DateTime.now().toIso8601String()),
      endTime: json['end_time'] != null ? DateTime.parse(json['end_time']) : DateTime.now(),
      duration: (json['duration'] as num?)?.toDouble() ?? 0.0,
      distance: (json['distance'] as num?)?.toDouble(),
      activeCalories: (json['statistics']?['activeEnergy']?['sum'] as num?)?.toDouble(),
      statistics: WorkoutStatistics.fromJson(json['statistics'] ?? {}),
      quantitySeries: (json['routeData']?['samples'] as List<dynamic>?)
              ?.map((e) => QuantitySeries.fromSamplesJson(e))
              .toList() ??
          [],
      route: (json['routeData']?['locations'] as List<dynamic>?)
              ?.map((e) => RouteLocation.fromJson(e))
              .toList() ??
          [],
      events: (json['events'] as List<dynamic>?)
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

  factory WorkoutStatistics.fromJson(Map<String, dynamic> json) {
    return WorkoutStatistics(
      avgHeartRate: (json['heartRate']?['average'] as num?)?.toDouble(),
      maxHeartRate: (json['heartRate']?['maximum'] as num?)?.toDouble(),
      avgPower: (json['cyclingPower']?['average'] as num?)?.toDouble() ?? (json['runningPower']?['average'] as num?)?.toDouble(),
      avgCadence: (json['cyclingCadence']?['average'] as num?)?.toDouble(),
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
      timestamp: DateTime.parse(json['timestamp'] ?? DateTime.now().toIso8601String()),
    );
  }
}

class WorkoutEvent {
  final String type;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  WorkoutEvent({
    required this.type,
    required this.timestamp,
    this.metadata,
  });

  factory WorkoutEvent.fromJson(Map<String, dynamic> json) {
    return WorkoutEvent(
      type: json['type'] ?? '',
      timestamp: DateTime.parse(json['timestamp'] ?? DateTime.now().toIso8601String()),
      metadata: json['metadata'],
    );
  }
}
