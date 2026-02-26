//
//  interval_step.dart
//  humango_health
//

import '../enums/workout_enums.dart';
import 'workout_step.dart';
import 'workout_goal.dart';
import 'workout_alert.dart';

/// Represents an IntervalStep (a specialized WorkoutStep used inside blocks).
class IntervalStep extends WorkoutStep {
  IntervalStep({
    required WorkoutGoal goal,
    WorkoutAlert? alert,
    required WorkoutStepType stepType,
  }) : super(goal: goal, alert: alert, stepType: stepType);

  @override
  bool isValid() {
    // Unlike standard steps, interval steps usually require a goal to determine block switch.
    return goal != null && goal!.isValid();
  }

  /// Deserializes from JSON.
  factory IntervalStep.fromJson(Map<String, dynamic> json) {
    return IntervalStep(
      stepType: WorkoutStepType.values.byName(json['stepType'] as String),
      goal: WorkoutGoal.fromJson(json['goal']),
      alert: json['alert'] != null ? WorkoutAlert.fromJson(json['alert']) : null,
    );
  }
}
