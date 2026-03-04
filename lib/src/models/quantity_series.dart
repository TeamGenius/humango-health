class QuantitySeries {
  final String type;
  final List<QuantityPoint> points;

  QuantitySeries({required this.type, required this.points});

  /// The iOS `RouteService` returns samples as `[[HKQuantitySample]]` where each array
  /// belongs to one specific HKQuantityTypeIdentifier.
  factory QuantitySeries.fromSamplesJson(dynamic jsonElement) {
    if (jsonElement is List && jsonElement.isNotEmpty) {
      final firstPoint = jsonElement.first;
      final type = firstPoint['quantityType'] as String? ?? 'unknown';

      final points = jsonElement.map((p) => QuantityPoint.fromJson(p)).toList();

      return QuantitySeries(type: type, points: points);
    }
    return QuantitySeries(type: 'empty', points: []);
  }
}

class QuantityPoint {
  final DateTime timestamp;
  final double value;
  final String unit;

  QuantityPoint({
    required this.timestamp,
    required this.value,
    required this.unit,
  });

  factory QuantityPoint.fromJson(Map<String, dynamic> json) {
    return QuantityPoint(
      timestamp: DateTime.parse(
          json['startDate'] ?? DateTime.now().toIso8601String()),
      value: (json['value'] as num?)?.toDouble() ?? 0.0,
      unit: json['unit'] ?? '',
    );
  }
}
