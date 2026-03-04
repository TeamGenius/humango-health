//
//  workout_push_manager.dart
//  humango_health
//

import 'package:flutter/services.dart';
import '../models/workout_plan.dart';
import '../models/workout_push_authorization_result.dart';
import '../models/workout_push_response.dart';
import '../storage/workout_push_record.dart';
import '../storage/workout_storage.dart';
import '../validation/workout_validator.dart';
import '../validation/validation_errors.dart';
import '../utils/workout_comparator.dart';

/// The central Dart manager for pushing WorkoutPlans to Apple Health via WorkoutKit.
class WorkoutPushManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.workouts/workoutplan',
  );

  final WorkoutStorage _storage = WorkoutStorage();
  final WorkoutValidator _validator = WorkoutValidator();

  /// Requests authorization for pushing workouts to Apple Watch via WorkoutKit.
  ///
  /// Returns a map containing:
  /// - `status`: The authorization status ('notDetermined', 'authorized', 'denied', or 'unknown')
  /// - `authorized`: Boolean indicating if authorization was granted
  ///
  /// This method should be called before attempting to push workouts to ensure
  /// the user has granted the necessary permissions.
  ///
  /// Throws an exception if the device doesn't support WorkoutKit (requires iOS 17.0+).
  Future<WorkoutPushAuthorizationResult>
  requestAuthorizationForWorkoutPush() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'requestAuthorizationForWorkoutPush',
      );
      if (result != null) {
        return WorkoutPushAuthorizationResult.fromMap(result);
      }
      return WorkoutPushAuthorizationResult.unknown();
    } catch (e) {
      return WorkoutPushAuthorizationResult.error(e.toString());
    }
  }

  /// Pushes a batch of raw backend JSON workouts to iOS via WorkoutKit.
  /// Handles deduplication offline by calculating raw payload sizes and extracting IDs.
  Future<WorkoutPushResponse> pushRawWorkouts(
    List<Map<String, dynamic>> workouts,
  ) async {
    List<Map<String, dynamic>> plansToPush = [];
    List<WorkoutPushResult> finalResults = [];
    int successful = 0;
    int skipped = 0;
    int failed = 0;

    for (var jsonMap in workouts) {
      // 1. Extract robust ID (Mirroring iOS extract logic)
      String? planId;
      if (jsonMap['schedule_id'] != null) {
        planId = jsonMap['schedule_id'].toString();
      } else if (jsonMap['id'] != null) {
        planId = jsonMap['id'].toString();
      } else if (jsonMap['workout_id'] != null) {
        planId = jsonMap['workout_id'].toString();
      } else if (jsonMap['workoutId'] != null) {
        planId = jsonMap['workoutId'].toString();
      } else {
        planId = DateTime.now().millisecondsSinceEpoch.toString(); // Fallback
      }

      // 2. Check Dart-layer Deduplication
      final existingRecord = await _storage.getRecord(planId);
      final currentSize = WorkoutComparator.calculateJsonSize(jsonMap);

      bool needsPush = true;
      if (existingRecord != null) {
        if (existingRecord.jsonSizeBytes == currentSize) {
          needsPush = false;
        }
      }

      if (needsPush) {
        plansToPush.add(jsonMap);
      } else {
        finalResults.add(WorkoutPushResult.skipped(planId));
        skipped++;
      }
    }

    // 3. Dispatch to Native iOS if work remains
    if (plansToPush.isNotEmpty) {
      try {
        final response = await _channel.invokeMethod(
          'scheduleWorkoutsFromFlutter',
          plansToPush,
        );

        if (response != null && response is Map) {
          final List<dynamic>? pushedArray =
              response['scheduledRecords'] as List<dynamic>?;

          if (pushedArray != null) {
            for (var resultData in pushedArray) {
              final Map<String, dynamic> recordMap = Map<String, dynamic>.from(
                resultData,
              );
              final record = WorkoutPushRecord.fromJson(recordMap);

              await _storage.saveRecord(record);
              finalResults.add(WorkoutPushResult.success(record));
              successful++;
            }
          } else {
            failed += plansToPush.length;
            for (var p in plansToPush) {
              final id =
                  p['id']?.toString() ??
                  p['workout_id']?.toString() ??
                  'unknown';
              finalResults.add(
                WorkoutPushResult(
                  workoutId: id,
                  status: WorkoutPushStatus.failed,
                  errorMessage:
                      "Missing detailed scheduled record array from iOS",
                ),
              );
            }
          }
        }
      } catch (e) {
        for (var p in plansToPush) {
          final id =
              p['id']?.toString() ?? p['workout_id']?.toString() ?? 'unknown';
          finalResults.add(
            WorkoutPushResult(
              workoutId: id,
              status: WorkoutPushStatus.failed,
              errorMessage: e.toString(),
            ),
          );
          failed++;
        }
      }
    }

    return WorkoutPushResponse(
      results: finalResults,
      totalSubmitted: workouts.length,
      successful: successful,
      skipped: skipped,
      failed: failed,
    );
  }

  /// Manually wipe the local cache to force a re-sync on the next push.
  Future<void> clearDeduplicationCache() async {
    await _storage.clearAll();
  }
}
