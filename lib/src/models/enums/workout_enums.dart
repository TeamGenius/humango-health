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

/// Represents a sport type for the `sport` field in raw workout push JSON.
/// Mirrors the iOS native `Sport` enum exactly — 10 supported cases.
/// Use [jsonValue] when building push payloads; use [AppleSportExtension.fromJsonValue]
/// when parsing received workout data (e.g. [ScheduledWorkoutInfo.sport]).
enum AppleSport {
  running,
  cycling,
  swimming,
  poolSwimming,
  openWaterSwimming,
  strength,
  hiking,
  walking,
  rowing,
  elliptical,
}

extension AppleSportExtension on AppleSport {
  /// The JSON string sent to / received from the iOS native layer.
  /// Matches the raw value of the Swift `Sport` enum (SCREAMING_SNAKE_CASE).
  /// Example: `AppleSport.poolSwimming.jsonValue` → `'POOL_SWIMMING'`
  String get jsonValue {
    switch (this) {
      case AppleSport.running:
        return 'RUNNING';
      case AppleSport.cycling:
        return 'CYCLING';
      case AppleSport.swimming:
        return 'SWIMMING';
      case AppleSport.poolSwimming:
        return 'POOL_SWIMMING';
      case AppleSport.openWaterSwimming:
        return 'OPEN_WATER_SWIMMING';
      case AppleSport.strength:
        return 'STRENGTH';
      case AppleSport.hiking:
        return 'HIKING';
      case AppleSport.walking:
        return 'WALKING';
      case AppleSport.rowing:
        return 'ROWING';
      case AppleSport.elliptical:
        return 'ELLIPTICAL';
    }
  }

  /// Parses a raw JSON string back into an [AppleSport].
  /// Returns `null` for unknown or empty values — safe for forward-compatibility.
  /// Example: `AppleSportExtension.fromJsonValue('POOL_SWIMMING')` → `AppleSport.poolSwimming`
  static AppleSport? fromJsonValue(String value) {
    switch (value) {
      case 'RUNNING':
        return AppleSport.running;
      case 'CYCLING':
        return AppleSport.cycling;
      case 'SWIMMING':
        return AppleSport.swimming;
      case 'POOL_SWIMMING':
        return AppleSport.poolSwimming;
      case 'OPEN_WATER_SWIMMING':
        return AppleSport.openWaterSwimming;
      case 'STRENGTH':
        return AppleSport.strength;
      case 'HIKING':
        return AppleSport.hiking;
      case 'WALKING':
        return AppleSport.walking;
      case 'ROWING':
        return AppleSport.rowing;
      case 'ELLIPTICAL':
        return AppleSport.elliptical;
      default:
        return null;
    }
  }
}
