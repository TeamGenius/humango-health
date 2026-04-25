class QuantitySeries {
  final String type;
  final List<QuantityPoint> points;

  QuantitySeries({required this.type, required this.points});

  /// Parses quantity series from the iOS payload.
  ///
  /// Two formats are supported:
  /// 1. Formatted dict: `{ "type": "HKQuantity...", "series": [{ "value": ..., "timestamp": ... }] }`
  ///    — produced by `HuRouteData.toDict()` (used in readWorkouts / monitoring).
  /// 2. Raw array: `[{ "quantityType": "...", "startDate": "...", "value": ... }, ...]`
  ///    — legacy / raw sample array format.
  factory QuantitySeries.fromSamplesJson(dynamic jsonElement) {
    // Format 1: formatted dict with "type" and "series" keys
    if (jsonElement is Map) {
      final type = jsonElement['type'] as String? ?? 'unknown';
      final seriesList = jsonElement['series'] as List<dynamic>? ?? [];
      final points = seriesList.map((p) {
        final m = p as Map<String, dynamic>;
        return QuantityPoint(
          timestamp: DateTime.parse(
            m['timestamp'] ?? DateTime.now().toIso8601String(),
          ),
          value: (m['value'] as num?)?.toDouble() ?? 0.0,
          unit: '',
        );
      }).toList();
      return QuantitySeries(type: type, points: points);
    }

    // Format 2: raw array of sample objects
    if (jsonElement is List && jsonElement.isNotEmpty) {
      final firstPoint = jsonElement.first;
      final type = firstPoint['quantityType'] as String? ?? 'unknown';
      final points =
          jsonElement.map((p) => QuantityPoint.fromJson(p as Map<String, dynamic>)).toList();
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
