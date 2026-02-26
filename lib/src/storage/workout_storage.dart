//
//  workout_storage.dart
//  humango_health
//

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'workout_push_record.dart';

/// Dart-layer persistent storage mapping `workoutId` to a `WorkoutPushRecord`.
class WorkoutStorage {
  static const String _storageKey = "com.humango.workouts.pushed";
  SharedPreferences? _prefs;

  /// Initializes SharedPreferences instance.
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Get a single record by workoutId.
  Future<WorkoutPushRecord?> getRecord(String workoutId) async {
    await init();
    final String? jsonStr = _prefs!.getString('${_storageKey}_$workoutId');
    if (jsonStr == null) return null;

    try {
      final Map<String, dynamic> jsonMap = jsonDecode(jsonStr);
      return WorkoutPushRecord.fromJson(jsonMap);
    } catch (e) {
      return null; // Corrupted record
    }
  }

  /// Save a record.
  Future<void> saveRecord(WorkoutPushRecord record) async {
    await init();
    final String jsonStr = jsonEncode(record.toJson());
    await _prefs!.setString('${_storageKey}_${record.workoutId}', jsonStr);
  }

  /// Delete a record.
  Future<void> deleteRecord(String workoutId) async {
    await init();
    await _prefs!.remove('${_storageKey}_$workoutId');
  }

  /// Check if a workout is already pushed based on the local cache
  Future<bool> hasRecord(String workoutId) async {
    await init();
    return _prefs!.containsKey('${_storageKey}_$workoutId');
  }

  /// Clears all pushed workout records locally.
  Future<void> clearAll() async {
    await init();
    final keys = _prefs!.getKeys().where((k) => k.startsWith(_storageKey));
    for (String key in keys) {
      await _prefs!.remove(key);
    }
  }
}
