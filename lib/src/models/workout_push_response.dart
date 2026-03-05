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
  final String? skipReason;

  /// The JSON that was being pushed (for skipped/failed cases)
  final Map<String, dynamic>? currentJson;

  /// The existing JSON already stored (for skipped cases - allows comparison)
  final Map<String, dynamic>? existingJson;

  /// Size of current JSON in bytes
  final int? currentJsonSizeBytes;

  /// Size of existing JSON in bytes
  final int? existingJsonSizeBytes;

  /// WorkoutPlan ID if available
  final String? workoutPlanId;

  WorkoutPushResult({
    required this.workoutId,
    required this.status,
    this.record,
    this.errorMessage,
    this.skipReason,
    this.currentJson,
    this.existingJson,
    this.currentJsonSizeBytes,
    this.existingJsonSizeBytes,
    this.workoutPlanId,
  });

  factory WorkoutPushResult.success(WorkoutPushRecord record) {
    return WorkoutPushResult(
      workoutId: record.workoutId,
      status: WorkoutPushStatus.success,
      record: record,
      currentJson: record.workoutJson,
      workoutPlanId: record.workoutPlanId,
    );
  }

  factory WorkoutPushResult.skipped(
    String workoutId, {
    String? reason,
    Map<String, dynamic>? currentJson,
    Map<String, dynamic>? existingJson,
    int? currentJsonSizeBytes,
    int? existingJsonSizeBytes,
    String? workoutPlanId,
  }) {
    return WorkoutPushResult(
      workoutId: workoutId,
      status: WorkoutPushStatus.skipped,
      skipReason: reason ?? 'unchanged',
      currentJson: currentJson,
      existingJson: existingJson,
      currentJsonSizeBytes: currentJsonSizeBytes,
      existingJsonSizeBytes: existingJsonSizeBytes,
      workoutPlanId: workoutPlanId,
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
  success, // Successfully pushed natively
  skipped, // Skipped locally due to deduplication (No changes)
  failed, // Failed natively or locally
  validationError, // Failed Dart validation before push
}
