import 'sleep_stage.dart';

class SleepData {
  final DateTime date;            // Representing the start of the sleep session night
  final Duration totalInBed;      // Total interval duration Apple tracked
  final Duration totalAsleep;     // Derived natively from distinct asleep stages
  final double sleepScore;        // Calculated: (Total Asleep / Total InBed) * 100
  final List<SleepStage> stages;  // Granular history of all distinct stages (REM, Core, Deep, Awake)

  SleepData({
    required this.date,
    required this.totalInBed,
    required this.totalAsleep,
    required this.sleepScore,
    required this.stages,
  });

  factory SleepData.fromJson(Map<String, dynamic> json) {
    return SleepData(
      date: DateTime.parse(json['date']),
      totalInBed: Duration(seconds: json['totalInBedSeconds'] as int),
      totalAsleep: Duration(seconds: json['totalAsleepSeconds'] as int),
      sleepScore: (json['sleepScore'] as num).toDouble(),
      stages: (json['stages'] as List<dynamic>)
          .map((e) => SleepStage.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'date': date.toIso8601String(),
      'totalInBedSeconds': totalInBed.inSeconds,
      'totalAsleepSeconds': totalAsleep.inSeconds,
      'sleepScore': sleepScore,
      'stages': stages.map((s) => s.toJson()).toList(),
    };
  }
}
