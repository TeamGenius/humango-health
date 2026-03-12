//
//  workout_push_response.dart
//  humango_health
//

/// The final response returned to Flutter after pushing a batch of workouts.
class WorkoutPushResponse {
  final List<WorkoutPushResult> results;
  final int totalSubmitted;
  final int successful;
  final int skipped;
  final int failed;

  WorkoutPushResponse({
    required this.results,
    required this.totalSubmitted,
    required this.successful,
    required this.skipped,
    required this.failed,
  });
}

/// The result for an individual workout push attempt.
class WorkoutPushResult {
  final String scheduleId; // schedule_id from JSON (UUID)
  final String workoutId; // workout_id from JSON (e.g., "232550")
  final WorkoutPushStatus status;
  final String? errorMessage;
  final String? skipReason;

  /// The JSON that was being pushed (for skipped/failed cases)
  final Map<String, dynamic>? currentJson;

  /// The existing JSON already stored (for skipped cases - allows comparison)
  final Map<String, dynamic>? existingJson;

  /// SHA-256 hash of the current (incoming) JSON
  final String? currentJsonHash;

  /// SHA-256 hash of the existing stored JSON
  final String? existingJsonHash;

  /// WorkoutPlan ID if available
  final String? workoutPlanId;

  WorkoutPushResult({
    required this.scheduleId,
    required this.workoutId,
    required this.status,
    this.errorMessage,
    this.skipReason,
    this.currentJson,
    this.existingJson,
    this.currentJsonHash,
    this.existingJsonHash,
    this.workoutPlanId,
  });

  factory WorkoutPushResult.skipped(
    String scheduleId,
    String workoutId, {
    String? reason,
    Map<String, dynamic>? currentJson,
    Map<String, dynamic>? existingJson,
    String? currentJsonHash,
    String? existingJsonHash,
    String? workoutPlanId,
  }) {
    return WorkoutPushResult(
      scheduleId: scheduleId,
      workoutId: workoutId,
      status: WorkoutPushStatus.skipped,
      skipReason: reason ?? 'unchanged',
      currentJson: currentJson,
      existingJson: existingJson,
      currentJsonHash: currentJsonHash,
      existingJsonHash: existingJsonHash,
      workoutPlanId: workoutPlanId,
    );
  }

  factory WorkoutPushResult.validationError(
    String scheduleId,
    String workoutId,
    String error,
  ) {
    return WorkoutPushResult(
      scheduleId: scheduleId,
      workoutId: workoutId,
      status: WorkoutPushStatus.validationError,
      errorMessage: error,
    );
  }
}

enum WorkoutPushStatus {
  success, // Successfully pushed natively
  skipped, // Skipped due to deduplication (No changes)
  failed, // Failed natively or locally
  validationError, // Failed validation before push
}
