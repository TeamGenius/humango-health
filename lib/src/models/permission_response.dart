import 'health_data_type.dart';
import 'permission_status.dart';

class PermissionResponse {
  final Map<HealthDataType, PermissionStatus> readStatuses;
  final Map<HealthDataType, PermissionStatus> writeStatuses;

  PermissionResponse({
    required this.readStatuses,
    required this.writeStatuses,
  });

  factory PermissionResponse.fromJson(Map<String, dynamic> json) {
    final Map<HealthDataType, PermissionStatus> readMap = {};
    if (json['readStatuses'] != null) {
      final readJson = Map<String, dynamic>.from(json['readStatuses'] as Map);
      readJson.forEach((key, value) {
        final type = HealthDataTypeExtension.fromIdentifier(key);
        if (type != null) {
          readMap[type] = PermissionStatusExtension.fromString(value as String);
        }
      });
    }

    final Map<HealthDataType, PermissionStatus> writeMap = {};
    if (json['writeStatuses'] != null) {
      final writeJson = Map<String, dynamic>.from(json['writeStatuses'] as Map);
      writeJson.forEach((key, value) {
        final type = HealthDataTypeExtension.fromIdentifier(key);
        if (type != null) {
          writeMap[type] = PermissionStatusExtension.fromString(value as String);
        }
      });
    }

    return PermissionResponse(
      readStatuses: readMap,
      writeStatuses: writeMap,
    );
  }
}
