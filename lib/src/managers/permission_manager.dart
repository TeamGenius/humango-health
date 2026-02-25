import 'dart:async';
import 'package:flutter/services.dart';

import '../models/health_data_type.dart';
import '../models/permission_response.dart';

class PermissionManager {
  static const MethodChannel _methodChannel = MethodChannel('com.humango.workouts/permissions');
  static const EventChannel _eventChannel = EventChannel('com.humango.workouts/permissions/stream');

  /// Checks current authorization status for specified data types.
  Future<PermissionResponse> verify(
    List<HealthDataType> readTypes,
    List<HealthDataType> writeTypes,
  ) async {
    final args = {
      'readTypes': readTypes.map((t) => t.identifier).toList(),
      'writeTypes': writeTypes.map((t) => t.identifier).toList(),
    };

    final result = await _methodChannel.invokeMapMethod<String, dynamic>('verify', args);
    if (result == null) {
      throw Exception('Failed to receive response from verify method');
    }
    return PermissionResponse.fromJson(result);
  }

  /// Requests authorization for specified data types. (Fire-and-forget)
  Future<void> request(
    List<HealthDataType> readTypes,
    List<HealthDataType> writeTypes,
  ) async {
    final args = {
      'readTypes': readTypes.map((t) => t.identifier).toList(),
      'writeTypes': writeTypes.map((t) => t.identifier).toList(),
    };
    await _methodChannel.invokeMethod('request', args);
  }

  /// Creates stream that emits permission status updates.
  Stream<PermissionResponse> listen(
    List<HealthDataType> readTypes,
    List<HealthDataType> writeTypes,
  ) {
    final args = {
      'readTypes': readTypes.map((t) => t.identifier).toList(),
      'writeTypes': writeTypes.map((t) => t.identifier).toList(),
    };

    return _eventChannel.receiveBroadcastStream(args).map((event) {
      final resultMap = Map<String, dynamic>.from(event as Map);
      return PermissionResponse.fromJson(resultMap);
    });
  }
}
