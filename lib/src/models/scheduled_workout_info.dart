/// Represents a workout that is currently scheduled on Apple Watch via WorkoutKit.
class ScheduledWorkoutInfo {
  /// The unique identifier from WorkoutKit (UUID).
  final String id;

  /// The WorkoutPlan ID from Apple's WorkoutKit (UUID).
  /// This is the stable identifier used to track the workout in WorkoutScheduler.
  final String? workoutPlanId;

  /// The workout ID from the original push (schedule_id).
  /// May be null if the workout was not matched with local records.
  final String? workoutId;

  /// The scheduled date and time for the workout.
  final DateTime? scheduledDate;

  /// The name of the workout.
  final String? name;

  /// The activity type (e.g., "Running", "Cycling", "Swimming").
  final String? activityType;

  /// The full workout JSON that was pushed.
  /// Available if the workout was matched with local records.
  final Map<String, dynamic>? workoutJson;

  /// Size of the stored JSON in bytes.
  final int? jsonSizeBytes;

  ScheduledWorkoutInfo({
    required this.id,
    this.workoutPlanId,
    this.workoutId,
    this.scheduledDate,
    this.name,
    this.activityType,
    this.workoutJson,
    this.jsonSizeBytes,
  });

  /// Creates a [ScheduledWorkoutInfo] from a native platform map.
  factory ScheduledWorkoutInfo.fromMap(Map<dynamic, dynamic> map) {
    DateTime? scheduledDate;
    if (map['scheduledDate'] != null) {
      scheduledDate = DateTime.tryParse(map['scheduledDate'] as String);
    }

    Map<String, dynamic>? workoutJson;
    if (map['workoutJson'] != null) {
      workoutJson = Map<String, dynamic>.from(map['workoutJson'] as Map);
    }

    return ScheduledWorkoutInfo(
      id: map['id'] as String? ?? '',
      workoutPlanId: map['workoutPlanId'] as String?,
      workoutId: map['workoutId'] as String?,
      scheduledDate: scheduledDate,
      name: map['name'] as String?,
      activityType: map['activityType'] as String?,
      workoutJson: workoutJson,
      jsonSizeBytes: map['jsonSizeBytes'] as int?,
    );
  }

  @override
  String toString() {
    return 'ScheduledWorkoutInfo(id: $id, workoutPlanId: $workoutPlanId, workoutId: $workoutId, scheduledDate: $scheduledDate, name: $name, activityType: $activityType, jsonSizeBytes: $jsonSizeBytes)';
  }
}
