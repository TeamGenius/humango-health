//
//  workout_push_manager.dart
//  humango_health
//

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/workout_push_authorization_result.dart';
import '../models/workout_push_response.dart';
import '../models/scheduled_workout_info.dart';
import '../storage/workout_push_record.dart';
import '../storage/workout_storage.dart';
import '../utils/workout_comparator.dart';

/// The central Dart manager for pushing WorkoutPlans to Apple Health via WorkoutKit.
class WorkoutPushManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.workouts/workoutplan',
  );

  final WorkoutStorage _storage = WorkoutStorage();

  /// Retrieves the list of currently scheduled workouts from Apple Watch via WorkoutKit.
  ///
  /// Returns a list of [ScheduledWorkoutInfo] containing details about each scheduled workout:
  /// - `id`: The WorkoutKit UUID
  /// - `workoutId`: The original schedule_id (if matched with local records)
  /// - `scheduledDate`: When the workout is scheduled
  /// - `name`: The workout name
  /// - `activityType`: The activity type (Running, Cycling, etc.)
  ///
  /// Requires iOS 17.0+. Returns an empty list on unsupported devices.
  Future<List<ScheduledWorkoutInfo>> getScheduledWorkouts() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'getScheduledWorkouts',
      );
      if (result != null) {
        return result
            .map(
              (item) => ScheduledWorkoutInfo.fromMap(
                Map<dynamic, dynamic>.from(item as Map),
              ),
            )
            .toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

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
  ///
  /// **Required fields for each workout JSON:**
  /// - `schedule_id`: Unique identifier for the workout (String or int)
  /// - `date`: ISO8601 formatted date string for scheduling
  /// - `blocks`: Non-empty array of interval blocks
  ///
  /// **Validation Behavior:**
  /// If ANY workout in the batch is missing required fields, the ENTIRE batch
  /// will be rejected and all workouts will be marked as failed with validation errors.
  ///
  /// Handles deduplication offline by calculating raw payload sizes and extracting IDs.
  Future<WorkoutPushResponse> pushRawWorkouts(
    List<Map<String, dynamic>> workouts,
  ) async {
    // MARK: - Strict Validation (All or Nothing)
    // Validate ALL workouts first - if ANY fails, reject the entire batch
    final validationErrors = <Map<String, dynamic>>[];

    for (int i = 0; i < workouts.length; i++) {
      final jsonMap = workouts[i];
      final errors = <String>[];

      // 1. Validate schedule_id (REQUIRED)
      if (jsonMap['schedule_id'] == null) {
        errors.add("Missing required field: 'schedule_id'");
      }

      // 2. Validate date (REQUIRED)
      final dateValue = jsonMap['date'];
      if (dateValue == null) {
        errors.add("Missing required field: 'date'");
      } else if (dateValue is! String) {
        errors.add(
          "Invalid 'date' type: expected String, got ${dateValue.runtimeType}",
        );
      } else {
        // Try to parse the date
        final parsedDate = DateTime.tryParse(dateValue);
        if (parsedDate == null) {
          errors.add(
            "Invalid date format: '$dateValue'. Expected ISO8601 format.",
          );
        }
      }

      // 3. Validate blocks (REQUIRED and non-empty)
      final blocks = jsonMap['blocks'];
      if (blocks == null) {
        errors.add(
          "Missing required field: 'blocks' (must be a non-empty array)",
        );
      } else if (blocks is! List) {
        errors.add(
          "Invalid 'blocks' type: expected List, got ${blocks.runtimeType}",
        );
      } else if (blocks.isEmpty) {
        errors.add("'blocks' array cannot be empty");
      }

      if (errors.isNotEmpty) {
        validationErrors.add({
          'index': i,
          'schedule_id': jsonMap['schedule_id']?.toString() ?? 'N/A',
          'errors': errors,
          'failedJson': jsonMap,
        });
      }
    }

    // If ANY validation errors exist, reject the ENTIRE batch
    if (validationErrors.isNotEmpty) {
      final errorDetails = validationErrors
          .map((error) {
            final idx = error['index'] as int;
            final scheduleId = error['schedule_id'] as String;
            final errs = error['errors'] as List<String>;
            return "Workout[$idx] (schedule_id: $scheduleId): ${errs.join(', ')}";
          })
          .join('; ');

      debugPrint(
        '\u274c [Humango Health] Validation failed for ${validationErrors.length} workout(s): $errorDetails',
      );

      // Return all workouts as failed with validation errors
      final failedResults = <WorkoutPushResult>[];
      for (var error in validationErrors) {
        final scheduleId = error['schedule_id'] as String;
        final errs = error['errors'] as List<String>;
        final failedJson = error['failedJson'] as Map<String, dynamic>;

        failedResults.add(
          WorkoutPushResult(
            workoutId: scheduleId,
            status: WorkoutPushStatus.validationError,
            errorMessage: errs.join(', '),
            currentJson: failedJson,
          ),
        );
      }

      return WorkoutPushResponse(
        results: failedResults,
        totalSubmitted: workouts.length,
        successful: 0,
        skipped: 0,
        failed: workouts.length,
      );
    }

    // All workouts passed validation, continue with processing
    List<Map<String, dynamic>> plansToPush = [];
    List<WorkoutPushResult> finalResults = [];
    int successful = 0;
    int skipped = 0;
    int failed = 0;

    for (var jsonMap in workouts) {
      // Extract schedule_id (guaranteed to exist after validation)
      final planId = jsonMap['schedule_id'].toString();

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
        // Include both JSONs for user comparison
        finalResults.add(
          WorkoutPushResult.skipped(
            planId,
            reason: 'dart_dedup_unchanged',
            currentJson: jsonMap,
            existingJson: existingRecord?.workoutJson,
            currentJsonSizeBytes: currentSize,
            existingJsonSizeBytes: existingRecord?.jsonSizeBytes,
            workoutPlanId: existingRecord?.workoutPlanId,
          ),
        );
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

              // Check status from iOS response
              final status = recordMap['status'] as String?;
              final workoutId = recordMap['workoutId'] as String? ?? 'unknown';

              if (status == 'skipped') {
                // Skipped by iOS deduplication - extract JSON details for comparison
                final reason =
                    recordMap['reason'] as String? ?? 'ios_unchanged';
                final currentJson =
                    recordMap['currentJson'] as Map<String, dynamic>?;
                final existingJson =
                    recordMap['existingJson'] as Map<String, dynamic>?;
                final currentJsonSizeBytes =
                    recordMap['currentJsonSizeBytes'] as int?;
                final existingJsonSizeBytes =
                    recordMap['existingJsonSizeBytes'] as int?;
                final workoutPlanId = recordMap['workoutPlanId'] as String?;

                finalResults.add(
                  WorkoutPushResult.skipped(
                    workoutId,
                    reason: reason,
                    currentJson: currentJson,
                    existingJson: existingJson,
                    currentJsonSizeBytes: currentJsonSizeBytes,
                    existingJsonSizeBytes: existingJsonSizeBytes,
                    workoutPlanId: workoutPlanId,
                  ),
                );
                skipped++;
              } else {
                // Scheduled successfully
                final record = WorkoutPushRecord.fromJson(recordMap);
                await _storage.saveRecord(record);
                finalResults.add(WorkoutPushResult.success(record));
                successful++;
              }
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
