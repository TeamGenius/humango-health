//
//  workout_validator.dart
//  humango_health
//

import 'validation_errors.dart';
import '../models/workout_plan.dart';
import '../models/workouts/custom_workout.dart';
import '../models/workout_components/interval_block.dart';

/// Centralized validation engine for evaluating batches of WorkoutPlans against iOS constraints.
class WorkoutValidator {
  static const int maxBatchSize = 50;
  
  /// High level validation evaluating the entire list
  List<ValidationResult> validateBatch(List<WorkoutPlan> workouts) {
    if (workouts.length > maxBatchSize) {
      throw BatchSizeExceededError("Cannot schedule more than $maxBatchSize workouts at once.");
    }
    
    return workouts.map((workout) => validateWorkout(workout)).toList();
  }

  /// Validates a single WorkoutPlan
  ValidationResult validateWorkout(WorkoutPlan plan) {
    List<ValidationError> errors = [];

    // 1. ID Check
    if (plan.id.isEmpty) {
      errors.add(MissingWorkoutIdError("WorkoutPlan must have a non-empty ID."));
    }

    // 2. Date Check (Cannot be more than 5 minutes in the past natively, must be within 7 days)
    final now = DateTime.now();
    final sevenDaysFromNow = now.add(const Duration(days: 7));
    if (plan.scheduledDate.isBefore(now.subtract(const Duration(minutes: 5)))) {
      errors.add(InvalidDateTimeError("Workout scheduledDate cannot be in the past."));
    }
    if (plan.scheduledDate.isAfter(sevenDaysFromNow)) {
      errors.add(InvalidDateTimeError("WorkoutKit only supports scheduling workouts within 7 days."));
    }

    // 3. Structural checks
    if (!plan.workout.toJson().isNotEmpty) {
      errors.add(InvalidWorkoutStructureError("Workout structure failed serialization checks."));
    }

    // 4. Custom Workout Interval limitations
    if (plan.workout is CustomWorkout) {
      final custom = plan.workout as CustomWorkout;
      if (custom.blocks.isEmpty && custom.warmup == null && custom.cooldown == null) {
        errors.add(InvalidWorkoutStructureError("CustomWorkout must have at least one step or block."));
      }

      for (var block in custom.blocks) {
        if (block.steps.isEmpty) {
          errors.add(EmptyIntervalBlockError("IntervalBlock cannot be empty. It must contain at least one step."));
        }
      }
    }

    if (errors.isEmpty) {
      return ValidationResult.success();
    } else {
      return ValidationResult.failure(errors);
    }
  }
}
