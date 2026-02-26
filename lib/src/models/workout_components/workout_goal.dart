//
//  workout_goal.dart
//  humango_health
//

import '../enums/workout_enums.dart';

/// Represents a WorkoutGoal natively mapped.
class WorkoutGoal {
  final WorkoutGoalType type;
  final double targetValue;
  final WorkoutGoalUnit unit;

  WorkoutGoal({
    required this.type,
    required this.targetValue,
    required this.unit,
  });

  /// Validates the goal structure.
  bool isValid() {
    if (type == WorkoutGoalType.open) {
      return true; // Open goals don't need values/units strictly validating.
    }
    return targetValue > 0 && _isUnitValidForType();
  }

  bool _isUnitValidForType() {
    switch (type) {
      case WorkoutGoalType.distance:
        return unit == WorkoutGoalUnit.meters ||
               unit == WorkoutGoalUnit.kilometers ||
               unit == WorkoutGoalUnit.miles;
      case WorkoutGoalType.time:
        return unit == WorkoutGoalUnit.seconds ||
               unit == WorkoutGoalUnit.minutes ||
               unit == WorkoutGoalUnit.hours;
      case WorkoutGoalType.energy:
        return unit == WorkoutGoalUnit.calories ||
               unit == WorkoutGoalUnit.kilojoules;
      default:
        return true;
    }
  }

  /// Serializes into JSON.
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'targetValue': targetValue,
      'unit': unit.name,
    };
  }

  /// Deserializes from JSON.
  factory WorkoutGoal.fromJson(Map<String, dynamic> json) {
    return WorkoutGoal(
      type: WorkoutGoalType.values.byName(json['type'] as String),
      targetValue: (json['targetValue'] as num).toDouble(),
      unit: WorkoutGoalUnit.values.byName(json['unit'] as String),
    );
  }
}
