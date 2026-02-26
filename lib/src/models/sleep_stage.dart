class SleepStage {
  final String stage;
  final DateTime startDate;
  final DateTime endDate;

  SleepStage({
    required this.stage,
    required this.startDate,
    required this.endDate,
  });

  factory SleepStage.fromJson(Map<String, dynamic> json) {
    return SleepStage(
      stage: json['stage'] as String,
      startDate: DateTime.parse(json['startDate']),
      endDate: DateTime.parse(json['endDate']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'stage': stage,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
    };
  }
}
