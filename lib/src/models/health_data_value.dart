class HealthDataValue {
  final double? numericValue;     // For quantity types
  final String? unit;             // For quantity types (e.g., "ms", "count")
  final String? categoryValue;    // For category types (e.g., "inBed", "asleepDeep")

  bool get isQuantity => numericValue != null;
  bool get isCategory => categoryValue != null;

  HealthDataValue.quantity({
    required this.numericValue,
    required this.unit,
  }) : categoryValue = null;

  HealthDataValue.category({
    required this.categoryValue,
  }) : numericValue = null,
       unit = null;

  factory HealthDataValue.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('numericValue') || json.containsKey('unit')) {
      return HealthDataValue.quantity(
        numericValue: (json['numericValue'] as num?)?.toDouble(),
        unit: json['unit'] as String?,
      );
    } else if (json.containsKey('categoryValue')) {
      final valueObj = json['categoryValue'];
      return HealthDataValue.category(
        categoryValue: valueObj is String ? valueObj : valueObj.toString(),
      );
    } else {
      // Fallback
      return HealthDataValue.quantity(numericValue: null, unit: null);
    }
  }

  Map<String, dynamic> toJson() {
    if (isQuantity) {
      return {
        'numericValue': numericValue,
        'unit': unit,
      };
    } else {
      return {
        'categoryValue': categoryValue,
      };
    }
  }
}
