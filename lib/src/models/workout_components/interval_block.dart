//
//  interval_block.dart
//  humango_health
//

import 'interval_step.dart';

/// Represents a repeating block of steps natively mapped to iOS `IntervalBlock`.
class IntervalBlock {
  final List<IntervalStep> steps;
  final int iterations;

  IntervalBlock({
    required this.steps,
    required this.iterations,
  });

  /// Validates the block structure.
  bool isValid() {
    return steps.isNotEmpty &&
           iterations >= 1 &&
           steps.every((step) => step.isValid());
  }

  /// Serializes into JSON.
  Map<String, dynamic> toJson() {
    return {
      'steps': steps.map((s) => s.toJson()).toList(),
      'iterations': iterations,
    };
  }

  /// Deserializes from JSON.
  factory IntervalBlock.fromJson(Map<String, dynamic> json) {
    return IntervalBlock(
      steps: (json['steps'] as List<dynamic>)
          .map((s) => IntervalStep.fromJson(s as Map<String, dynamic>))
          .toList(),
      iterations: json['iterations'] as int,
    );
  }
}
