//
//  workout_base.dart
//  humango_health
//

import '../enums/workout_enums.dart';

/// Abstract base class for all WorkoutKit equivalent workouts natively mapped.
abstract class WorkoutBase {
  /// The activity type of the workout (e.g. running, cycling, swimming, etc.).
  final WorkoutActivityType activityType;

  /// The location of the workout (e.g. indoor, outdoor, unknown).
  final WorkoutLocation location;

  WorkoutBase({
    required this.activityType,
    required this.location,
  });

  /// Abstract method to serialize the workout to a JSON dictionary.
  Map<String, dynamic> toJson();
}
