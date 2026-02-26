import 'package:flutter/services.dart';
import '../models/sleep_data.dart';

class SleepDataManager {
  static const MethodChannel _methodChannel = MethodChannel('com.humango.workouts/sleep');

  /// Fetches aggregated nightly sleep periods for the past N days.
  /// Resolves all overlapping raw intervals to calculate total InBed, Asleep, and a Sleep Score.
  Future<List<SleepData>> readSleepData({int pastDays = 7}) async {
    try {
      final List<dynamic>? results = await _methodChannel.invokeMethod('readSleepData', {
        'pastDays': pastDays,
      });
      
      if (results == null) return [];

      return results.map((e) => SleepData.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      print("Error fetching sleep data: $e");
      return [];
    }
  }

  /// Fetches the most recent night's fully aggregated sleep record.
  /// Equivalent to `readSleepData(pastDays: 1)` but specifically returning a single, finalized record from the last recorded night.
  Future<SleepData?> getCurrentRecord() async {
    try {
      final List<SleepData> results = await readSleepData(pastDays: 1);
      if (results.isNotEmpty) {
        return results.first;
      }
      return null;
    } catch (e) {
      print("Error fetching current sleep record: $e");
      return null;
    }
  }
}
