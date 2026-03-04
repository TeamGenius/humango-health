import 'health_data_type.dart';
import 'permission_status.dart';

class HealthKitAuthorizationResult {
  final bool isAuthorized;
  final Map<HealthDataType, PermissionStatus> statuses;

  HealthKitAuthorizationResult({
    required this.isAuthorized,
    required this.statuses,
  });

  factory HealthKitAuthorizationResult.fromMap(Map map) {
    final statuses = <HealthDataType, PermissionStatus>{};

    // Safely map the specific swift string keys to our Dart HealthDataTypes
    final keyMapping = {
      'workoutStatus': HealthDataType.workout,
      'activeEnergyStatus': HealthDataType.activeCalories,
      'distanceStatus': HealthDataType.distance,
      'stepsStatus': HealthDataType.steps,
      'sleepStatus': HealthDataType.sleepAnalysis,
      'hrvStatus': HealthDataType.hrv,
      'restingHeartRateStatus': HealthDataType.restingHeartRate,
      'heartRateStatus': HealthDataType.heartRate,
      'bodyMassStatus': HealthDataType.bodyMass,
      'heightStatus': HealthDataType.height,
      'bodyFatStatus': HealthDataType.bodyFatPercentage,
    };

    keyMapping.forEach((key, type) {
      if (map.containsKey(key)) {
        statuses[type] = PermissionStatusExtension.fromString(
          map[key] as String,
        );
      }
    });

    return HealthKitAuthorizationResult(
      isAuthorized: map['isAuthorized'] ?? false,
      statuses: statuses,
    );
  }

  factory HealthKitAuthorizationResult.error() {
    final statuses = <HealthDataType, PermissionStatus>{};
    for (var type in HealthDataType.values) {
      statuses[type] = PermissionStatus.denied; // Fail closed
    }

    return HealthKitAuthorizationResult(
      isAuthorized: false,
      statuses: statuses,
    );
  }

  /// Returns true if any tracked permission was explicitly denied
  bool get hasAnyDenied {
    return statuses.values.any((status) => status == PermissionStatus.denied);
  }

  /// Returns true if any tracked permission has no data in HealthKit
  bool get hasAnyNoData {
    return statuses.values.any((status) => status == PermissionStatus.noData);
  }

  /// Returns true if all tracked permissions are either authorized or noData (likely all granted)
  bool get isLikelyFullyGranted {
    return statuses.values.every((status) => status.isLikelyGranted);
  }

  /// Returns true if any tracked permission has not been requested yet
  bool get hasAnyUnknown {
    return statuses.values.any((status) => status == PermissionStatus.unknown);
  }
}
