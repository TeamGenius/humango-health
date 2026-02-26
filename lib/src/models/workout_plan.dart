//
//  workout_plan.dart
//  humango_health
//

import 'workouts/workout_base.dart';

/// A wrapper orchestrating a WorkoutBase alongside scheduling instructions natively mapped.
class WorkoutPlan {
  final String id;
  final DateTime scheduledDate;
  final WorkoutBase workout;

  WorkoutPlan({
    required this.id,
    required this.scheduledDate,
    required this.workout,
  });

  /// Validates the full plan.
  bool isValid() {
    // Only permit workouts dynamically scheduled for the future.
    return id.isNotEmpty &&
           scheduledDate.isAfter(DateTime.now().subtract(const Duration(minutes: 5))) &&
           workout.toJson().isNotEmpty; // Validates serialization logic
  }

  /// Serializes into JSON.
  Map<String, dynamic> toJson() {
    // Merge the base instructions and dates together for iOS ingestion matching WorkoutPlanBuilder expectations!
    return {
      'id': id,
      'date': scheduledDate.toUtc().toIso8601String(),
      'workout': workout.toJson(),
    };
  }
}
