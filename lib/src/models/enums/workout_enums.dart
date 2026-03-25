//
//  workout_enums.dart
//  humango_health
//

/// Represents an iOS HKWorkoutActivityType natively mapped.
enum WorkoutActivityType {
  running,
  cycling,
  swimming,
  walking,
  hiking,
  yoga,
  functionalStrengthTraining,
  traditionalStrengthTraining,
  coreTraining,
  flexibility,
  cooldown,
  highIntensityIntervalTraining,
  rowing,
  elliptical,
  stairClimbing,
  triathlon,
  paddleSports,
  downhillSkiing,
  mixedCardio,
  crossCountrySkiing,
  snowSports,
  soccer,
  tennis,
  squash,
  pickleball,
  badminton,
  baseball,
  hockey,
  volleyball,
  handball,
  basketball,
  swimBikeRun,
  other,
}

/// Represents an iOS HKWorkoutSessionLocationType natively mapped.
enum WorkoutLocation { indoor, outdoor, unknown }

/// Represents the type of step in a CustomWorkout natively mapped.
enum WorkoutStepType { work, recovery, warmup, cooldown }

/// Represents the type of goal natively mapped.
enum WorkoutGoalType { distance, time, energy, open }

/// Represents the unit for a given WorkoutGoal natively mapped.
enum WorkoutGoalUnit {
  meters,
  kilometers,
  miles,
  seconds,
  minutes,
  hours,
  calories,
  kilojoules,
}

/// Represents the type of alert for a WorkoutStep natively mapped.
enum WorkoutAlertType { heartRate, pace, power, cadence, time, distance }

/// Represents the metric scope for a given WorkoutAlert natively mapped.
enum WorkoutAlertMetric { current, average, zone }
