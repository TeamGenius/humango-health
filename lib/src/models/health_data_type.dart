enum HealthDataType {
  hrv,
  restingHeartRate,
  sleepAnalysis,
  workout,
  activeCalories,
  steps,
  bodyMass,
  height,
  bodyFatPercentage,
  vo2Max,
  respiratoryRate,
  oxygenSaturation,
  distance,
  biologicalSex,
}

extension HealthDataTypeExtension on HealthDataType {
  String get identifier {
    switch (this) {
      case HealthDataType.hrv:
        return 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN';
      case HealthDataType.restingHeartRate:
        return 'HKQuantityTypeIdentifierRestingHeartRate';
      case HealthDataType.sleepAnalysis:
        return 'HKCategoryTypeIdentifierSleepAnalysis';
      case HealthDataType.steps:
        return 'HKQuantityTypeIdentifierStepCount';
      case HealthDataType.activeCalories:
        return 'HKQuantityTypeIdentifierActiveEnergyBurned';
      case HealthDataType.bodyMass:
        return 'HKQuantityTypeIdentifierBodyMass';
      case HealthDataType.height:
        return 'HKQuantityTypeIdentifierHeight';
      case HealthDataType.bodyFatPercentage:
        return 'HKQuantityTypeIdentifierBodyFatPercentage';
      case HealthDataType.vo2Max:
        return 'HKQuantityTypeIdentifierVO2Max';
      case HealthDataType.respiratoryRate:
        return 'HKQuantityTypeIdentifierRespiratoryRate';
      case HealthDataType.oxygenSaturation:
        return 'HKQuantityTypeIdentifierOxygenSaturation';
      case HealthDataType.distance:
        return 'HKQuantityTypeIdentifierDistanceWalkingRunning';
      case HealthDataType.workout:
        return 'HKWorkoutType';
      case HealthDataType.biologicalSex:
        return 'HKCharacteristicTypeIdentifierBiologicalSex';
    }
  }

  static HealthDataType? fromIdentifier(String identifier) {
    for (var type in HealthDataType.values) {
      if (type.identifier == identifier) return type;
    }
    return null;
  }
}
