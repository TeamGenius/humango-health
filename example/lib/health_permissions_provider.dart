import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';
import 'dart:async';

class HealthPermissionsProvider with ChangeNotifier {
  final PermissionManager _permissionManager = PermissionManager();
  StreamSubscription<HealthKitAuthorizationResult>? _permissionSubscription;

  bool _isAuthorized = false;
  Map<HealthDataType, PermissionStatus> _statuses = {};
  String _streamError = "";

  bool get isAuthorized => _isAuthorized;
  Map<HealthDataType, PermissionStatus> get statuses => _statuses;
  String get streamError => _streamError;

  bool get hasAnyDenied =>
      _statuses.values.any((s) => s == PermissionStatus.denied);

  HealthPermissionsProvider() {
    _startListening();
  }

  void _startListening() {
    _permissionSubscription = _permissionManager.permissionStream.listen(
      (HealthKitAuthorizationResult result) {
        print("Provider received stream update: ${result.statuses}");
        _isAuthorized = result.isAuthorized;
        _statuses = result.statuses;
        _streamError = "";
        notifyListeners();
      },
      onError: (error) {
        _streamError = "Stream Error: $error";
        notifyListeners();
      },
    );
  }

  Future<void> verifyPermissions() async {
    try {
      final HealthKitAuthorizationResult result = await _permissionManager
          .verifyAuthorization();
      _isAuthorized = result.isAuthorized;
      _statuses = result.statuses;
      _streamError = "";
      notifyListeners();
    } catch (e) {
      _streamError = "Error verifying: $e";
      notifyListeners();
    }
  }

  /// Requests the full fixed HealthKit type set (all tracked types).
  Future<void> requestPermissions() async {
    try {
      await _permissionManager.requestAuthorization();
      // Statuses will be updated implicitly when the
      // EventChannel stream fires upon returning from Settings!
    } catch (e) {
      _streamError = "Error requesting permissions: $e";
      notifyListeners();
    }
  }

  /// Requests only workout-related permissions.
  /// On iOS, [HealthDataType.workout] automatically expands to all ancillary
  /// types: heartRate, stepCount, distanceCycling, swimmingStrokeCount,
  /// distanceSwimming, vo2Max, distanceWalkingRunning, activeEnergyBurned,
  /// bodyMassIndex, running/cycling biomechanics, and workoutRoute.
  Future<void> requestWorkoutPermissions() async {
    try {
      await _permissionManager.requestAuthorization(
        readTypes: [HealthDataType.workout],
      );
    } catch (e) {
      _streamError = "Error requesting workout permissions: $e";
      notifyListeners();
    }
  }

  /// Requests only sleep-related permissions.
  Future<void> requestSleepPermissions() async {
    try {
      await _permissionManager.requestAuthorization(
        readTypes: [HealthDataType.sleepAnalysis],
      );
    } catch (e) {
      _streamError = "Error requesting sleep permissions: $e";
      notifyListeners();
    }
  }

  /// Requests permissions for a custom set of [HealthDataType] values.
  Future<void> requestPermissionsForTypes(
    List<HealthDataType> readTypes,
  ) async {
    try {
      await _permissionManager.requestAuthorization(readTypes: readTypes);
    } catch (e) {
      _streamError = "Error requesting permissions: $e";
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _permissionSubscription?.cancel();
    super.dispose();
  }
}
