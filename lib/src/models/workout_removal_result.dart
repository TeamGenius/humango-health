//
//  workout_removal_result.dart
//  humango_health
//

/// Status of a single workout removal operation.
enum WorkoutRemovalStatus {
  /// Successfully removed from Apple Watch and local storage.
  success,

  /// Not found on Apple Watch but removed from local storage.
  partial,

  /// Not found on Apple Watch or in local storage.
  fail,
}

/// Result of removing a single scheduled workout by its workoutPlanId.
class WorkoutRemovalResult {
  /// The WorkoutPlan ID that was requested for removal.
  final String workoutPlanId;

  /// The schedule_id of the matched local record, if found.
  final String? scheduleId;

  /// The workout_id of the matched local record, if found.
  final String? workoutId;

  /// The status of the removal operation.
  final WorkoutRemovalStatus status;

  /// Human-readable message describing the result.
  final String message;

  const WorkoutRemovalResult({
    required this.workoutPlanId,
    this.scheduleId,
    this.workoutId,
    required this.status,
    required this.message,
  });

  factory WorkoutRemovalResult.fromMap(Map<dynamic, dynamic> map) {
    final statusStr = map['status'] as String? ?? 'fail';
    final WorkoutRemovalStatus status;
    switch (statusStr) {
      case 'success':
        status = WorkoutRemovalStatus.success;
        break;
      case 'partial':
        status = WorkoutRemovalStatus.partial;
        break;
      default:
        status = WorkoutRemovalStatus.fail;
    }

    return WorkoutRemovalResult(
      workoutPlanId: map['workoutPlanId'] as String? ?? '',
      scheduleId: map['scheduleId'] as String?,
      workoutId: map['workoutId'] as String?,
      status: status,
      message: map['message'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
    'workoutPlanId': workoutPlanId,
    if (scheduleId != null) 'scheduleId': scheduleId,
    if (workoutId != null) 'workoutId': workoutId,
    'status': status.name,
    'message': message,
  };

  @override
  String toString() =>
      'WorkoutRemovalResult(planId: $workoutPlanId, scheduleId: $scheduleId, workoutId: $workoutId, status: ${status.name}, message: $message)';
}
