//
//  workout_comparator.dart
//  humango_health
//

import 'dart:convert';
import '../models/workout_plan.dart';
import '../storage/workout_push_record.dart';

/// Handles deduplication logic by comparing current logic to the cached records.
class WorkoutComparator {
  /// Calculates the exact byte length of the UTF-8 encoded serialized JSON.
  static int calculateJsonSize(Map<String, dynamic> jsonMap) {
    final String jsonString = jsonEncode(jsonMap);
    return utf8.encode(jsonString).length;
  }

  /// Evaluates whether the incoming [WorkoutPlan] needs to be pushed natively.
  /// Deduplication Rules:
  /// 1. If [existingRecord] is null, it's new -> PUSH.
  /// 2. If the 'scheduledDateTime' string changed -> PUSH.
  /// 3. If the [currentJsonSizeBytes] does not match the byte length in [existingRecord] -> PUSH.
  /// 4. Otherwise, it is an exact duplicate -> SKIP.
  static bool needsPush(
    WorkoutPlan plan,
    WorkoutPushRecord? existingRecord,
    int currentJsonSizeBytes,
  ) {
    // Rule 1: Not found remotely
    if (existingRecord == null) {
      return true;
    }

    // Rule 2: Scheduled Date changed
    final dateString = plan.scheduledDate.toUtc().toIso8601String();
    if (existingRecord.scheduledDateTime != dateString) {
      return true;
    }

    // Rule 3: Payload structure changed
    if (existingRecord.jsonSizeBytes != currentJsonSizeBytes) {
      return true;
    }

    // Rule 4: Match, skip it
    return false;
  }
}
