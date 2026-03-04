enum PermissionStatus {
  unknown, // Not requested — user hasn't seen the HealthKit prompt yet
  authorized, // Permission granted and data confirmed available
  denied, // Permission denied or was previously authorized then revoked
  noData, // Permission was prompted, but no data exists in HealthKit for this type
}

extension PermissionStatusExtension on PermissionStatus {
  String get name {
    switch (this) {
      case PermissionStatus.unknown:
        return 'unknown';
      case PermissionStatus.authorized:
        return 'authorized';
      case PermissionStatus.denied:
        return 'denied';
      case PermissionStatus.noData:
        return 'noData';
    }
  }

  /// Whether this status should be treated as "not authorized" for gating purposes.
  /// noData is NOT effectively denied — the user likely granted access but has no recorded data.
  bool get isEffectivelyDenied {
    return this == PermissionStatus.denied;
  }

  /// Whether this status means the app can potentially read data (granted or will have data later)
  bool get isLikelyGranted {
    return this == PermissionStatus.authorized ||
        this == PermissionStatus.noData;
  }

  static PermissionStatus fromString(String status) {
    switch (status) {
      case 'authorized':
        return PermissionStatus.authorized;
      case 'denied':
        return PermissionStatus.denied;
      case 'noData':
        return PermissionStatus.noData;
      case 'unknown':
      default:
        return PermissionStatus.unknown;
    }
  }
}
