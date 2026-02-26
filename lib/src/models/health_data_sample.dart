import 'health_data_value.dart';
import 'health_data_type.dart';

class HealthDataSample {
  final HealthDataType type;              // Mapped back to enum
  final HealthDataValue value;    // Quantity or category value
  final DateTime startDate;
  final DateTime endDate;
  final String? sourceApp;        // App that recorded the sample
  final String? sourceDevice;     // Device that recorded the sample
  final Map<String, dynamic>? metadata;

  HealthDataSample({
    required this.type,
    required this.value,
    required this.startDate,
    required this.endDate,
    this.sourceApp,
    this.sourceDevice,
    this.metadata,
  });

  factory HealthDataSample.fromJson(Map<String, dynamic> json) {
    final nativeTypeIdentifier = json['type'] as String;
    final type = HealthDataTypeExtension.fromIdentifier(nativeTypeIdentifier) ?? HealthDataType.workout;

    return HealthDataSample(
      type: type,
      value: HealthDataValue.fromJson(Map<String, dynamic>.from(json['value'] ?? {})),
      startDate: DateTime.parse(json['startDate'] as String),
      endDate: DateTime.parse(json['endDate'] as String),
      sourceApp: json['sourceApp'] as String?,
      sourceDevice: json['sourceDevice'] as String?,
      metadata: json['metadata'] != null ? Map<String, dynamic>.from(json['metadata']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type.identifier,
      'value': value.toJson(),
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'sourceApp': sourceApp,
      'sourceDevice': sourceDevice,
      'metadata': metadata,
    };
  }
}
