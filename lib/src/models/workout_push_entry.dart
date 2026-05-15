//
//  workout_push_entry.dart
//  humango_health
//

import 'enums/workout_enums.dart';

/// A typed entry for pushing a workout via [WorkoutPushManager.pushRawWorkouts].
///
/// Instead of building raw [Map<String, dynamic>] payloads by hand, construct a
/// [WorkoutPushEntry] so that [scheduleId] and [sport] are enforced at compile
/// time — eliminating typos and incorrect casing on the `schedule_id` and
/// `sport` keys.
///
/// The [data] map is the raw workout JSON from your backend. It must contain:
/// - `date`: ISO8601 string for the scheduled date
/// - `blocks`: non-empty list of interval blocks
///
/// `schedule_id` and `sport` from [data] are **overwritten** by the typed fields
/// on this class, so there is no conflict even if your backend blob includes them.
///
/// Example:
/// ```dart
/// final entry = WorkoutPushEntry(
///   scheduleId: 'abc-123',
///   sport: AppleSport.running,
///   metricType: MetricType.metric,
///   data: backendWorkoutJson,  // map from your server
/// );
/// await workoutPushManager.pushRawWorkouts([entry]);
/// ```
class WorkoutPushEntry {
  /// The unique identifier for this scheduled workout.
  /// Becomes the `schedule_id` key in the serialized map sent to iOS.
  final String scheduleId;

  /// The sport / activity type.
  /// Becomes the `sport` key in the serialized map (e.g. `'RUNNING'`).
  final AppleSport sport;

  /// The measurement system preference.
  /// Becomes the `metric_type` key in the serialized map (e.g. `'IMPERIAL'`).
  /// Determines which units Apple Watch displays for distance-based goals:
  /// - [MetricType.imperial]: mile (non-swimming) / yard (swimming)
  /// - [MetricType.metric]: km (non-swimming) / meter (swimming)
  /// - [MetricType.unspecified]: falls back to per-workout `unit` field or defaults
  final MetricType metricType;

  /// The raw workout payload from your backend.
  /// Must contain `date` (ISO8601 string) and `blocks` (non-empty list).
  final Map<String, dynamic> data;

  const WorkoutPushEntry({
    required this.scheduleId,
    required this.sport,
    required this.metricType,
    required this.data,
  });

  /// Serializes this entry into the map format expected by the iOS native layer.
  /// [scheduleId], [sport.jsonValue], and [metricType.jsonValue] always override
  /// any values in [data].
  Map<String, dynamic> toMap() {
    return {
      ...data,
      'schedule_id': scheduleId,
      'sport': sport.jsonValue,
      'metric_type': metricType.jsonValue,
    };
  }
}
