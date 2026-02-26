import 'health_data_type.dart';

class HealthDataReadOptions {
  final HealthDataType type;
  final DateTime startDate;
  final DateTime endDate;
  final int? limit;               // Max samples to return

  HealthDataReadOptions({
    required this.type,
    required this.startDate,
    required this.endDate,
    this.limit,
  });

  Map<String, dynamic> toJson() => {
    'type': type.identifier,
    'startDate': startDate.toIso8601String(),
    'endDate': endDate.toIso8601String(),
    'limit': limit,
  };
}
