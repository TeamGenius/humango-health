//
//  swim_bike_run_workout.dart
//  humango_health
//

import '../enums/workout_enums.dart';
import 'workout_base.dart';
import 'single_goal_workout.dart';
import 'custom_workout.dart';

/// Represents a complex Triathlon Workout mapped to WorkoutKit `SwimBikeRunWorkout`.
class SwimBikeRunWorkout extends WorkoutBase {
  final SingleGoalWorkout swim;
  final CustomWorkout bike;
  final CustomWorkout run;
  final String? displayName;

  SwimBikeRunWorkout({
    required this.swim,
    required this.bike,
    required this.run,
    this.displayName,
  }) : super(
          activityType: WorkoutActivityType.triathlon,
          location: WorkoutLocation.outdoor,
        );

  /// Validates the structure.
  bool isValid() {
    return swim.activityType == WorkoutActivityType.swimming &&
           bike.activityType == WorkoutActivityType.cycling &&
           run.activityType == WorkoutActivityType.running &&
           swim.isValid() &&
           bike.isValid() &&
           run.isValid();
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'swimBikeRun',
      'displayName': displayName,
      'swim': swim.toJson(),
      'bike': bike.toJson(),
      'run': run.toJson(),
    };
  }
}
