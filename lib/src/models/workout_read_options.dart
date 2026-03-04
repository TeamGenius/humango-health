class WorkoutReadOptions {
  final DateTime startDate;
  final DateTime endDate;
  final bool includeRunning;
  final bool includeCycling;
  final bool includeSwimming;
  final bool includeOther;

  WorkoutReadOptions({
    required this.startDate,
    required this.endDate,
    this.includeRunning = true,
    this.includeCycling = true,
    this.includeSwimming = true,
    this.includeOther = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'startDate': startDate.toUtc().toIso8601String(),
      'endDate': endDate.toUtc().toIso8601String(),
      'includeRunning': includeRunning,
      'includeCycling': includeCycling,
      'includeSwimming': includeSwimming,
      'includeOther': includeOther,
    };
  }
}
