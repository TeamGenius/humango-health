//
//  workout_alert.dart
//  humango_health
//

import '../enums/workout_enums.dart';

/// Represents a WorkoutAlert natively mapped.
class WorkoutAlert {
  final WorkoutAlertType type;
  final double? targetValue; // For single-value metric alerts
  final WorkoutAlertMetric? metric;

  WorkoutAlert({
    required this.type,
    this.targetValue,
    this.metric,
  });

  /// Serializes into JSON.
  Map<String, dynamic> toJson() {
    return {
      'type': type.name,
      'targetValue': targetValue,
      'metric': metric?.name,
    };
  }

  /// Deserializes from JSON.
  factory WorkoutAlert.fromJson(Map<String, dynamic> json) {
    return WorkoutAlert(
      type: WorkoutAlertType.values.byName(json['type'] as String),
      targetValue: json['targetValue'] != null ? (json['targetValue'] as num).toDouble() : null,
      metric: json['metric'] != null ? WorkoutAlertMetric.values.byName(json['metric'] as String) : null,
    );
  }
}
