//
//  validation_errors.dart
//  humango_health
//

/// Represents the output of a validation pass.
class ValidationResult {
  final bool isValid;
  final List<ValidationError> errors;

  ValidationResult({
    required this.isValid,
    required this.errors,
  });

  factory ValidationResult.success() {
    return ValidationResult(isValid: true, errors: []);
  }

  factory ValidationResult.failure(List<ValidationError> errors) {
    return ValidationResult(isValid: false, errors: errors);
  }
}

/// Abstract base class for all validation errors.
abstract class ValidationError {
  final String message;
  ValidationError(this.message);

  @override
  String toString() => message;
}

class InvalidDateTimeError extends ValidationError {
  InvalidDateTimeError(String msg) : super("InvalidDateTimeError: $msg");
}

class BatchSizeExceededError extends ValidationError {
  BatchSizeExceededError(String msg) : super("BatchSizeExceededError: $msg");
}

class MissingWorkoutIdError extends ValidationError {
  MissingWorkoutIdError(String msg) : super("MissingWorkoutIdError: $msg");
}

class EmptyIntervalBlockError extends ValidationError {
  EmptyIntervalBlockError(String msg) : super("EmptyIntervalBlockError: $msg");
}

class InvalidWorkoutStructureError extends ValidationError {
  InvalidWorkoutStructureError(String msg) : super("InvalidWorkoutStructureError: $msg");
}
