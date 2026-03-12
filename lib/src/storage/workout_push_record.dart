//
//  workout_push_record.dart
//  humango_health
//

/// Represents a local record of a pushed workout for deduplication.
class WorkoutPushRecord {
  final String scheduleId; // schedule_id from JSON (UUID)
  final String workoutId; // workout_id from JSON (e.g., "232550")
  final String workoutPlanId; // Apple's WorkoutPlan UUID
  final String scheduledDateTime; // ISO 8601
  final String jsonHash; // SHA-256 hex of sorted-key JSON bytes
  final String pushedAt; // ISO 8601
  final Map<String, dynamic>? workoutJson; // The full workout JSON

  WorkoutPushRecord({
    required this.scheduleId,
    required this.workoutId,
    required this.workoutPlanId,
    required this.scheduledDateTime,
    required this.jsonHash,
    required this.pushedAt,
    this.workoutJson,
  });

  Map<String, dynamic> toJson() {
    return {
      'scheduleId': scheduleId,
      'workoutId': workoutId,
      'workoutPlanId': workoutPlanId,
      'scheduledDateTime': scheduledDateTime,
      'jsonHash': jsonHash,
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
      // Backward-compat: fall back to legacy 'workoutId' key if scheduleId absent
      scheduleId:
          json['scheduleId'] as String? ?? json['workoutId'] as String? ?? '',
      workoutId: json['workoutId'] as String? ?? '',
      workoutPlanId: json['workoutPlanId'] as String? ?? '',
      scheduledDateTime: json['scheduledDateTime'] as String,
      jsonHash: json['jsonHash'] as String? ?? '',
      pushedAt: json['pushedAt'] as String,
      workoutJson: workoutJson,
    );
  }
}
