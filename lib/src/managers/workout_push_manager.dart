//
//  workout_push_manager.dart
//  humango_health
//

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/workout_push_authorization_result.dart';
import '../models/workout_push_response.dart';
import '../models/scheduled_workout_info.dart';
import '../models/workout_removal_result.dart';

/// The central Dart manager for pushing WorkoutPlans to Apple Health via WorkoutKit.
class WorkoutPushManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.workouts/workoutplan',
  );

  /// Retrieves the list of currently scheduled workouts from Apple Watch via WorkoutKit.
  ///
  /// Returns a list of [ScheduledWorkoutInfo] containing details about each scheduled workout:
  /// - `id`: The WorkoutKit UUID
  /// - `scheduleId`: The original schedule_id UUID from the push JSON
  /// - `workoutId`: The original workout_id from the push JSON
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
  /// Each workout is validated individually. Workouts that fail validation are
  /// recorded with `validationError` status. The remaining valid workouts are
  /// sent to native for scheduling. The final response consolidates all results:
  /// validation failures + native skipped + native scheduled.
  ///
  /// Handles deduplication offline by calculating raw payload sizes, comparing
  /// dates, and extracting IDs.
  Future<WorkoutPushResponse> pushRawWorkouts(
    List<Map<String, dynamic>> workouts,
  ) async {
    // Per-workout validation — collect failures, continue with valid ones
    final List<WorkoutPushResult> failedResults = [];
    final List<Map<String, dynamic>> validWorkouts = [];
    int failed = 0;

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
        final scheduleId = jsonMap['schedule_id']?.toString() ?? 'N/A';
        final workoutId = jsonMap['workout_id']?.toString() ?? 'N/A';
        debugPrint(
          '\u274c [Humango Health] Validation failed for workout[$i] (schedule_id: $scheduleId): ${errors.join(', ')}',
        );
        failedResults.add(
          WorkoutPushResult(
            scheduleId: scheduleId,
            workoutId: workoutId,
            status: WorkoutPushStatus.validationError,
            errorMessage: errors.join(', '),
            currentJson: jsonMap,
          ),
        );
        failed++;
      } else {
        validWorkouts.add(jsonMap);
      }
    }

    // All deduplication is handled natively — send valid workouts to iOS
    List<WorkoutPushResult> finalResults = [...failedResults];
    int successful = 0;
    int skipped = 0;

    if (validWorkouts.isNotEmpty) {
      try {
        final response = await _channel.invokeMethod(
          'scheduleWorkoutsFromFlutter',
          validWorkouts,
        );

        if (response != null && response is Map) {
          final List<dynamic>? pushedArray =
              response['scheduledRecords'] as List<dynamic>?;

          if (pushedArray != null) {
            for (var resultData in pushedArray) {
              final Map<String, dynamic> recordMap = Map<String, dynamic>.from(
                resultData,
              );

              final status = recordMap['status'] as String?;
              final scheduleId =
                  recordMap['scheduleId'] as String? ?? 'unknown';
              final workoutId = recordMap['workoutId'] as String? ?? 'unknown';

              if (status == 'skipped') {
                final reason =
                    recordMap['reason'] as String? ?? 'ios_unchanged';
                final currentJson = _toStringMap(recordMap['currentJson']);
                final existingJson = _toStringMap(recordMap['existingJson']);
                final currentJsonHash = recordMap['currentJsonHash'] as String?;
                final existingJsonHash =
                    recordMap['existingJsonHash'] as String?;
                final workoutPlanId = recordMap['workoutPlanId'] as String?;

                finalResults.add(
                  WorkoutPushResult.skipped(
                    scheduleId,
                    workoutId,
                    reason: reason,
                    currentJson: currentJson,
                    existingJson: existingJson,
                    currentJsonHash: currentJsonHash,
                    existingJsonHash: existingJsonHash,
                    workoutPlanId: workoutPlanId,
                  ),
                );
                skipped++;
              } else if (status == 'validation_error') {
                final reason =
                    recordMap['reason'] as String? ?? 'native_validation_error';
                finalResults.add(
                  WorkoutPushResult(
                    scheduleId: scheduleId,
                    workoutId: workoutId,
                    status: WorkoutPushStatus.validationError,
                    errorMessage: reason,
                    currentJson: _toStringMap(recordMap['currentJson']),
                  ),
                );
                failed++;
              } else if (status == 'device_not_supported') {
                finalResults.add(
                  WorkoutPushResult(
                    scheduleId: scheduleId,
                    workoutId: workoutId,
                    status: WorkoutPushStatus.failed,
                    errorMessage:
                        recordMap['reason'] as String? ??
                        'Device does not support scheduled workouts',
                    currentJson: _toStringMap(recordMap['currentJson']),
                  ),
                );
                failed++;
              } else if (status == 'scheduled') {
                // Scheduled successfully — native handles storage
                finalResults.add(
                  WorkoutPushResult(
                    scheduleId: scheduleId,
                    workoutId: workoutId,
                    status: WorkoutPushStatus.success,
                    workoutPlanId: recordMap['workoutPlanId'] as String?,
                    currentJson: _toStringMap(recordMap['workoutJson']),
                  ),
                );
                successful++;
              } else {
                // Unknown status — treat as success
                finalResults.add(
                  WorkoutPushResult(
                    scheduleId: scheduleId,
                    workoutId: workoutId,
                    status: WorkoutPushStatus.success,
                    workoutPlanId: recordMap['workoutPlanId'] as String?,
                  ),
                );
                successful++;
              }
            }
          } else {
            failed += validWorkouts.length;
            for (var p in validWorkouts) {
              final scheduleId = p['schedule_id']?.toString() ?? 'unknown';
              final id =
                  p['workout_id']?.toString() ??
                  p['id']?.toString() ??
                  'unknown';
              finalResults.add(
                WorkoutPushResult(
                  scheduleId: scheduleId,
                  workoutId: id,
                  status: WorkoutPushStatus.failed,
                  errorMessage:
                      'Missing detailed scheduled record array from iOS',
                ),
              );
            }
          }
        }
      } catch (e) {
        for (var p in validWorkouts) {
          final scheduleId = p['schedule_id']?.toString() ?? 'unknown';
          final id =
              p['workout_id']?.toString() ?? p['id']?.toString() ?? 'unknown';
          finalResults.add(
            WorkoutPushResult(
              scheduleId: scheduleId,
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

  /// Removes ALL scheduled workouts from Apple Watch and clears the entire
  /// local [ScheduledWorkoutStore] in a single native call.
  ///
  /// Returns a map with:
  /// - `removedFromWatch`: number of workouts removed from Apple Watch
  /// - `storeCleared`: true if the local store was cleared
  /// - `localRecordsCleared`: number of local records that were cleared
  ///
  /// Prefer this over the manual get → remove → clear sequence when you want
  /// a full reset. Requires iOS 17.0+.
  Future<Map<String, dynamic>> removeAllScheduledWorkouts() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'removeAllScheduledWorkouts',
      );
      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
      return {
        'removedFromWatch': 0,
        'storeCleared': false,
        'localRecordsCleared': 0,
      };
    } catch (e) {
      debugPrint('❌ [Humango Health] removeAllScheduledWorkouts failed: $e');
      return {
        'removedFromWatch': 0,
        'storeCleared': false,
        'error': e.toString(),
      };
    }
  }

  /// Clears the native-side deduplication cache (ScheduledWorkoutStore).
  /// Forces a full re-sync on the next push.
  Future<bool> clearDeduplicationCache() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'clearAppleScheduledWorkouts',
      );
      return result ?? false;
    } catch (e) {
      debugPrint('\u274c [Humango Health] Failed to clear native cache: $e');
      return false;
    }
  }

  /// Removes scheduled workouts from Apple Watch and local storage by their WorkoutPlan IDs.
  ///
  /// Accepts a list of `workoutPlanId` strings (the UUIDs assigned by WorkoutKit
  /// when the workout was originally scheduled).
  ///
  /// Returns a list of [WorkoutRemovalResult], one per requested ID, indicating:
  /// - `success` — removed from both Apple Watch and local storage
  /// - `partial` — not found on Apple Watch but cleaned from local storage
  /// - `fail` — not found anywhere
  ///
  /// Requires iOS 17.0+.
  Future<List<WorkoutRemovalResult>> removeScheduledWorkouts(
    List<String> workoutPlanIds,
  ) async {
    if (workoutPlanIds.isEmpty) return [];

    try {
      final response = await _channel.invokeMethod<List<dynamic>>(
        'removeScheduledWorkouts',
        workoutPlanIds,
      );

      if (response != null) {
        return response
            .map(
              (item) => WorkoutRemovalResult.fromMap(
                Map<dynamic, dynamic>.from(item as Map),
              ),
            )
            .toList();
      }
      return workoutPlanIds
          .map(
            (id) => WorkoutRemovalResult(
              workoutPlanId: id,
              status: WorkoutRemovalStatus.fail,
              message: 'No response from native layer',
            ),
          )
          .toList();
    } catch (e) {
      return workoutPlanIds
          .map(
            (id) => WorkoutRemovalResult(
              workoutPlanId: id,
              status: WorkoutRemovalStatus.fail,
              message: e.toString(),
            ),
          )
          .toList();
    }
  }

  /// Computes a SHA-256 hash of the given workout JSON map.
  ///
  /// The hash is generated natively on iOS using CryptoKit with sorted JSON keys,
  /// matching the exact hash stored in [WorkoutPushRecord.jsonHash] during scheduling.
  ///
  /// Returns the 64-character lowercase hex SHA-256 string, or `null` on failure.
  Future<String?> computeWorkoutJsonHash(Map<String, dynamic> jsonMap) async {
    try {
      final hash = await _channel.invokeMethod<String>(
        'computeWorkoutJsonHash',
        jsonMap,
      );
      return hash;
    } catch (e) {
      debugPrint('\u274c [Humango Health] Failed to compute JSON hash: $e');
      return null;
    }
  }

  /// Safely converts a method-channel map value to [Map<String, dynamic>].
  ///
  /// Flutter method channels return [Map<Object?, Object?>], which cannot be
  /// directly cast to [Map<String, dynamic>]. This helper does a safe conversion
  /// and returns null if the value is not a map.
  static Map<String, dynamic>? _toStringMap(Object? value) {
    if (value == null) return null;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}
