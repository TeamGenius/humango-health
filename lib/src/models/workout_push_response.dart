//
//  workout_push_response.dart
//  humango_health
//

import '../storage/workout_push_record.dart';

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
  final String workoutId;
  final WorkoutPushStatus status;
  final WorkoutPushRecord? record;
  final String? errorMessage;

  WorkoutPushResult({
    required this.workoutId,
    required this.status,
    this.record,
    this.errorMessage,
  });

  factory WorkoutPushResult.success(WorkoutPushRecord record) {
    return WorkoutPushResult(
      workoutId: record.workoutId,
      status: WorkoutPushStatus.success,
      record: record,
    );
  }

  factory WorkoutPushResult.skipped(String workoutId) {
    return WorkoutPushResult(
      workoutId: workoutId,
      status: WorkoutPushStatus.skipped,
    );
  }

  factory WorkoutPushResult.validationError(String workoutId, String error) {
    return WorkoutPushResult(
      workoutId: workoutId,
      status: WorkoutPushStatus.validationError,
      errorMessage: error,
    );
  }
}

enum WorkoutPushStatus {
  success,      // Successfully pushed natively
  skipped,      // Skipped locally due to deduplication (No changes)
  failed,       // Failed natively or locally
  validationError, // Failed Dart validation before push
}
