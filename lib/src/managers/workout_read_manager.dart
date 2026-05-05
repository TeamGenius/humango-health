import 'package:flutter/services.dart';
import '../models/workout_read_options.dart';

class WorkoutReadManager {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.humango.workouts/read',
  );

  /// Start continuous monitoring for workouts from the specified start date onwards.
  /// Monitoring is open-ended and will capture all future workouts.
  Future<void> startMonitoring(
    DateTime startDate, {
    WorkoutReadOptions? options,
  }) async {
    final args = {
      'startDate': startDate.toUtc().toIso8601String(),
      if (options != null) ...options.toJson(),
    };
    await _methodChannel.invokeMethod('startWorkoutMonitoring', args);
  }

  /// Stop live and background monitoring
  Future<void> stopMonitoring() async {
    await _methodChannel.invokeMethod('stopWorkoutMonitoring');
  }

  /// One-shot query for past workouts.
  /// [endDate] is optional and defaults to current time if not provided.
  Future<List<String>> readWorkouts(
    DateTime startDate, {
    DateTime? endDate,
    WorkoutReadOptions? options,
  }) async {
    final args = {
      'startDate': startDate.toUtc().toIso8601String(),
      if (endDate != null) 'endDate': endDate.toUtc().toIso8601String(),
      if (options != null) ...options.toJson(),
    };

    final result = await _methodChannel.invokeMethod('readWorkouts', args);
    // iOS returns an array of JSON strings
    if (result is List) {
      return result.cast<String>();
    }
    return [];
  }

  /// Fetches all workouts in the given date range directly from HealthKit.
  /// Every matching workout type is returned.
  Future<List<String>> fetchAllWorkouts(
    DateTime startDate, {
    DateTime? endDate,
  }) async {
    final args = {
      'startDate': startDate.toUtc().toIso8601String(),
      if (endDate != null) 'endDate': endDate.toUtc().toIso8601String(),
    };
    final result = await _methodChannel.invokeMethod('fetchAllWorkouts', args);
    if (result is List) return result.cast<String>();
    return [];
  }
}
