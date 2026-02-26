//
//  custom_workout.dart
//  humango_health
//

import '../enums/workout_enums.dart';
import 'workout_base.dart';
import '../workout_components/workout_step.dart';
import '../workout_components/interval_block.dart';

/// Represents a Custom Workout mapped to WorkoutKit `CustomWorkout`.
class CustomWorkout extends WorkoutBase {
  final WorkoutStep? warmup;
  final List<IntervalBlock> blocks;
  final WorkoutStep? cooldown;
  final String? displayName;

  CustomWorkout({
    required WorkoutActivityType activityType,
    required WorkoutLocation location,
    this.warmup,
    required this.blocks,
    this.cooldown,
    this.displayName,
  }) : super(activityType: activityType, location: location);

  /// Validates the structure.
  bool isValid() {
    return blocks.isNotEmpty &&
           blocks.every((block) => block.isValid()) &&
           (warmup?.isValid() ?? true) &&
           (cooldown?.isValid() ?? true);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'custom',
      'activityType': activityType.name,
      'location': location.name,
      'displayName': displayName,
      'warmup': warmup?.toJson(),
      'blocks': blocks.map((b) => b.toJson()).toList(),
      'cooldown': cooldown?.toJson(),
    };
  }
}
