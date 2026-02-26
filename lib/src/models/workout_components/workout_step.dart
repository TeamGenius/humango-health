//
//  workout_step.dart
//  humango_health
//

import '../enums/workout_enums.dart';
import 'workout_goal.dart';
import 'workout_alert.dart';

/// Represents a simple WorkoutStep natively mapped.
class WorkoutStep {
  final WorkoutGoal? goal;
  final WorkoutAlert? alert;
  final WorkoutStepType stepType;

  WorkoutStep({
    this.goal,
    this.alert,
    required this.stepType,
  });

  /// Validates the step structure.
  bool isValid() {
    return goal?.isValid() ?? true;
  }

  /// Serializes into JSON.
  Map<String, dynamic> toJson() {
    return {
      'stepType': stepType.name,
      'goal': goal?.toJson(),
      'alert': alert?.toJson(),
    };
  }

  /// Deserializes from JSON.
  factory WorkoutStep.fromJson(Map<String, dynamic> json) {
    return WorkoutStep(
      stepType: WorkoutStepType.values.byName(json['stepType'] as String),
      goal: json['goal'] != null ? WorkoutGoal.fromJson(json['goal']) : null,
      alert: json['alert'] != null ? WorkoutAlert.fromJson(json['alert']) : null,
    );
  }
}
