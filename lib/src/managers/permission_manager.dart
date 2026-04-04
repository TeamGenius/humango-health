import 'package:flutter/services.dart';
import '../models/health_data_type.dart';
import '../models/health_kit_authorization_result.dart';

class PermissionManager {
  static const MethodChannel _methodChannel = MethodChannel('healthkit/method');
  static const EventChannel _eventChannel = EventChannel('healthkit/event');

  Stream<HealthKitAuthorizationResult>? _permissionStream;

  /// Listen for permission updates explicitly mapped to our Result object
  Stream<HealthKitAuthorizationResult> get permissionStream {
    _permissionStream ??= _eventChannel.receiveBroadcastStream().map((event) {
      return HealthKitAuthorizationResult.fromMap(
        Map<dynamic, dynamic>.from(event),
      );
    });

    return _permissionStream!;
  }

  /// Request authorization for the given [readTypes].
  /// When [readTypes] is null, requests the full fixed type set (default behaviour).
  /// When provided, only those types are requested; on iOS, [HealthDataType.workout]
  /// automatically expands to all workout-ancillary types (heartRate, stepCount,
  /// distanceCycling, swimmingStrokeCount, distanceSwimming, vo2Max,
  /// distanceWalkingRunning, activeEnergyBurned, bodyMassIndex, running/cycling
  /// biomechanics, workoutRoute).
  Future<void> requestAuthorization({List<HealthDataType>? readTypes}) async {
    try {
      final args = readTypes != null
          ? {'types': readTypes.map((t) => t.identifier).toList()}
          : null;
      await _methodChannel.invokeMethod('requestAuthorization', args);
    } catch (e) {
      return;
    }
  }

  /// Verify authorization manually
  Future<HealthKitAuthorizationResult> verifyAuthorization() async {
    try {
      final Map<dynamic, dynamic> result = await _methodChannel.invokeMethod(
        'verifyAuthorization',
      );
      return HealthKitAuthorizationResult.fromMap(result);
    } catch (e) {
      return HealthKitAuthorizationResult.error();
    }
  }
}
