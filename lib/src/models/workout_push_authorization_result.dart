/// Represents the authorization status for pushing workouts via WorkoutKit.
enum WorkoutPushAuthorizationStatus {
  /// Authorization has not been requested yet.
  notDetermined,

  /// Authorization was granted.
  authorized,

  /// Authorization was denied.
  denied,

  /// Unknown authorization status.
  unknown,

  /// An error occurred while requesting authorization.
  error,
}

/// Result of requesting authorization for pushing workouts.
class WorkoutPushAuthorizationResult {
  /// The authorization status.
  final WorkoutPushAuthorizationStatus status;

  /// Whether the user has authorized workout push.
  final bool isAuthorized;

  /// Error message if an error occurred.
  final String? errorMessage;

  WorkoutPushAuthorizationResult({
    required this.status,
    required this.isAuthorized,
    this.errorMessage,
  });

  /// Creates a result from a native platform map.
  factory WorkoutPushAuthorizationResult.fromMap(Map<dynamic, dynamic> map) {
    final statusString = map['status'] as String? ?? 'unknown';
    final authorized = map['authorized'] as bool? ?? false;

    return WorkoutPushAuthorizationResult(
      status: _parseStatus(statusString),
      isAuthorized: authorized,
    );
  }

  /// Creates an unknown status result.
  factory WorkoutPushAuthorizationResult.unknown() {
    return WorkoutPushAuthorizationResult(
      status: WorkoutPushAuthorizationStatus.unknown,
      isAuthorized: false,
    );
  }

  /// Creates an error result with an error message.
  factory WorkoutPushAuthorizationResult.error(String message) {
    return WorkoutPushAuthorizationResult(
      status: WorkoutPushAuthorizationStatus.error,
      isAuthorized: false,
      errorMessage: message,
    );
  }

  static WorkoutPushAuthorizationStatus _parseStatus(String status) {
    switch (status) {
      case 'notDetermined':
        return WorkoutPushAuthorizationStatus.notDetermined;
      case 'authorized':
        return WorkoutPushAuthorizationStatus.authorized;
      case 'denied':
        return WorkoutPushAuthorizationStatus.denied;
      default:
        return WorkoutPushAuthorizationStatus.unknown;
    }
  }

  @override
  String toString() {
    return 'WorkoutPushAuthorizationResult(status: $status, isAuthorized: $isAuthorized, errorMessage: $errorMessage)';
  }
}
