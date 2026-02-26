//
//  workout_push_record.dart
//  humango_health
//

/// Represents a local record of a pushed workout for deduplication.
class WorkoutPushRecord {
  final String workoutId;
  final String scheduledDateTime; // ISO 8601
  final String hashValue; // Generated natively on iOS via WorkoutScheduler
  final int jsonSizeBytes;
  final String pushedAt; // ISO 8601

  WorkoutPushRecord({
    required this.workoutId,
    required this.scheduledDateTime,
    required this.hashValue,
    required this.jsonSizeBytes,
    required this.pushedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'workoutId': workoutId,
      'scheduledDateTime': scheduledDateTime,
      'hashValue': hashValue,
      'jsonSizeBytes': jsonSizeBytes,
      'pushedAt': pushedAt,
    };
  }

  factory WorkoutPushRecord.fromJson(Map<String, dynamic> json) {
    return WorkoutPushRecord(
      workoutId: json['workoutId'] as String,
      scheduledDateTime: json['scheduledDateTime'] as String,
      hashValue: json['hashValue'] as String,
      jsonSizeBytes: json['jsonSizeBytes'] as int,
      pushedAt: json['pushedAt'] as String,
    );
  }
}
