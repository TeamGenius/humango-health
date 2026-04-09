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
/// Mirrors the iOS native `Sport` enum exactly — 28 cases.
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
  yoga,
  paddling,
  alpineSkiing,
  rowing,
  cardio,
  nordicSkiing,
  snowshoeing,
  hiit,
  hyrox,
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
  multisport,
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
      case AppleSport.yoga:
        return 'YOGA';
      case AppleSport.paddling:
        return 'PADDLING';
      case AppleSport.alpineSkiing:
        return 'ALPINE_SKIING';
      case AppleSport.rowing:
        return 'ROWING';
      case AppleSport.cardio:
        return 'CARDIO';
      case AppleSport.nordicSkiing:
        return 'NORDIC_SKIING';
      case AppleSport.snowshoeing:
        return 'SNOWSHOEING';
      case AppleSport.hiit:
        return 'HIIT';
      case AppleSport.hyrox:
        return 'HYROX';
      case AppleSport.soccer:
        return 'SOCCER';
      case AppleSport.tennis:
        return 'TENNIS';
      case AppleSport.squash:
        return 'SQUASH';
      case AppleSport.pickleball:
        return 'PICKLEBALL';
      case AppleSport.badminton:
        return 'BADMINTON';
      case AppleSport.baseball:
        return 'BASEBALL';
      case AppleSport.hockey:
        return 'HOCKEY';
      case AppleSport.volleyball:
        return 'VOLLEYBALL';
      case AppleSport.handball:
        return 'HANDBALL';
      case AppleSport.basketball:
        return 'BASKETBALL';
      case AppleSport.multisport:
        return 'MULTISPORT';
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
      case 'YOGA':
        return AppleSport.yoga;
      case 'PADDLING':
        return AppleSport.paddling;
      case 'ALPINE_SKIING':
        return AppleSport.alpineSkiing;
      case 'ROWING':
        return AppleSport.rowing;
      case 'CARDIO':
        return AppleSport.cardio;
      case 'NORDIC_SKIING':
        return AppleSport.nordicSkiing;
      case 'SNOWSHOEING':
        return AppleSport.snowshoeing;
      case 'HIIT':
        return AppleSport.hiit;
      case 'HYROX':
        return AppleSport.hyrox;
      case 'SOCCER':
        return AppleSport.soccer;
      case 'TENNIS':
        return AppleSport.tennis;
      case 'SQUASH':
        return AppleSport.squash;
      case 'PICKLEBALL':
        return AppleSport.pickleball;
      case 'BADMINTON':
        return AppleSport.badminton;
      case 'BASEBALL':
        return AppleSport.baseball;
      case 'HOCKEY':
        return AppleSport.hockey;
      case 'VOLLEYBALL':
        return AppleSport.volleyball;
      case 'HANDBALL':
        return AppleSport.handball;
      case 'BASKETBALL':
        return AppleSport.basketball;
      case 'MULTISPORT':
        return AppleSport.multisport;
      default:
        return null;
    }
  }
}
