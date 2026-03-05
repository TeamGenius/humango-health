//
//  workout_push_record.dart
//  humango_health
//

/// Represents a local record of a pushed workout for deduplication.
class WorkoutPushRecord {
  final String workoutId;
  final String workoutPlanId; // Apple's WorkoutPlan UUID
  final String scheduledDateTime; // ISO 8601
  final int jsonSizeBytes;
  final String pushedAt; // ISO 8601
  final Map<String, dynamic>? workoutJson; // The full workout JSON

  WorkoutPushRecord({
    required this.workoutId,
    required this.workoutPlanId,
    required this.scheduledDateTime,
    required this.jsonSizeBytes,
    required this.pushedAt,
    this.workoutJson,
  });

  Map<String, dynamic> toJson() {
    return {
      'workoutId': workoutId,
      'workoutPlanId': workoutPlanId,
      'scheduledDateTime': scheduledDateTime,
      'jsonSizeBytes': jsonSizeBytes,
      'pushedAt': pushedAt,
      if (workoutJson != null) 'workoutJson': workoutJson,
    };
  }

  factory WorkoutPushRecord.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? workoutJson;
    if (json['workoutJson'] != null) {
      workoutJson = Map<String, dynamic>.from(json['workoutJson'] as Map);
    }

    return WorkoutPushRecord(
      workoutId: json['workoutId'] as String,
      workoutPlanId: json['workoutPlanId'] as String? ?? '',
      scheduledDateTime: json['scheduledDateTime'] as String,
      jsonSizeBytes: json['jsonSizeBytes'] as int,
      pushedAt: json['pushedAt'] as String,
      workoutJson: workoutJson,
    );
  }
}
