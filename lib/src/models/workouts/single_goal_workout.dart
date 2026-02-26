//
//  single_goal_workout.dart
//  humango_health
//

import '../enums/workout_enums.dart';
import 'workout_base.dart';
import '../workout_components/workout_goal.dart';

/// Represents a Single Goal Workout mapped to WorkoutKit `SingleGoalWorkout`.
class SingleGoalWorkout extends WorkoutBase {
  final WorkoutGoal goal;
  final String? displayName;

  SingleGoalWorkout({
    required WorkoutActivityType activityType,
    required WorkoutLocation location,
    required this.goal,
    this.displayName,
  }) : super(activityType: activityType, location: location);

  /// Validates the structure.
  bool isValid() {
    return goal.isValid();
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'singleGoal',
      'activityType': activityType.name,
      'location': location.name,
      'displayName': displayName,
      'goal': goal.toJson(),
    };
  }
}
