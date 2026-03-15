import 'package:flutter/services.dart';
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

  /// Request authorization because we will not get correct authorization here only by subscribing to stream and listening is one way and by verifying authorization
  Future<void> requestAuthorization() async {
    try {
      await _methodChannel.invokeMethod('requestAuthorization');
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
