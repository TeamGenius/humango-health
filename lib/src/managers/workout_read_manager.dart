import 'package:flutter/services.dart';
import '../models/background_delivery_config.dart';
import '../models/workout_read_options.dart';
import '../models/workout_store_record.dart';

class WorkoutReadManager {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.humango.workouts/read',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.humango.workouts/read/stream',
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
    // Allow a fresh stream to be created on next startMonitoring call
    _cachedStream = null;
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

  /// Arms native workout delivery: [workoutStream] when listening, else pending storage.
  /// Does not perform HTTP — upload from your app (Dart or Runner native).
  Future<void> configureBackgroundDelivery(
    BackgroundDeliveryConfig config,
  ) async {
    await _methodChannel.invokeMethod(
      'configureBackgroundDelivery',
      config.toJson(),
    );
  }

  /// Set workout type import preferences
  /// Controls which workout types should be imported during fetch/monitoring
  Future<void> setImportPreferences({
    required bool running,
    required bool cycling,
    required bool swimming,
  }) async {
    final args = {'running': running, 'cycling': cycling, 'swimming': swimming};
    await _methodChannel.invokeMethod('setImportPreferences', args);
  }

  /// Manually trigger foreground mode (usually handled by app lifecycle observer)
  Future<void> enterForegroundMode() async {
    await _methodChannel.invokeMethod('enterForeground');
  }

  /// Manually trigger background mode (usually handled by app lifecycle observer)
  Future<void> enterBackgroundMode() async {
    await _methodChannel.invokeMethod('enterBackground');
  }

  /// Notifies the native layer that the given workouts have been successfully
  /// pushed to the backend. This marks them as pushed in the local record store
  /// so they are excluded from future [readWorkouts] calls.
  ///
  /// [deviceActivityIds] — the list of `deviceActivityId` values returned
  /// inside each workout JSON from [readWorkouts].
  ///
  /// Returns the count of IDs that were marked.
  Future<int> markWorkoutsAsPushed(List<String> deviceActivityIds) async {
    if (deviceActivityIds.isEmpty) return 0;
    final result = await _methodChannel.invokeMethod<Map>(
      'markWorkoutsAsPushed',
      deviceActivityIds,
    );
    return (result?['markedCount'] as int?) ?? 0;
  }

  /// Fetches all workouts in the given date range directly from HealthKit,
  /// bypassing WorkoutRecordStore dedup. Every matching workout is returned
  /// regardless of whether it has been pushed before.
  ///
  /// Use this when you need a full unfiltered snapshot (e.g. audit, re-sync).
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

  /// Returns all records currently held in the native WorkoutRecordStore.
  ///
  /// Useful for debugging and testing — shows the pushed/pending state of
  /// every workout ID the library has seen.
  Future<List<WorkoutStoreRecord>> getWorkoutStoreRecords() async {
    final result = await _methodChannel.invokeMethod<List>(
      'getWorkoutStoreRecords',
    );
    if (result == null) return [];
    return result
        .cast<Map>()
        .map((m) => WorkoutStoreRecord.fromMap(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Cached broadcast stream so that receiveBroadcastStream() is only called
  /// once.  Recreating it on every widget build triggers onCancel → onListen on
  /// the native side, which momentarily sets the eventSink to nil and drops any
  /// workout events that arrive during the gap.
  static Stream<String>? _cachedStream;

  /// Stream of workouts captured in the foreground in real-time.
  Stream<String> get workoutStream {
    _cachedStream ??= _eventChannel.receiveBroadcastStream().map((event) {
      return event as String;
    });
    return _cachedStream!;
  }
}
