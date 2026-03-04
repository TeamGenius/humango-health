import 'package:flutter/services.dart';
import '../models/background_delivery_config.dart';
import '../models/workout_read_options.dart';

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

  /// Configure how background workouts are delivered (API vs Local Storage)
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

  /// Fetch workouts stored locally by the background observer.
  /// This automatically clears them from local storage after retrieval.
  Future<List<String>> getLocalWorkouts() async {
    final result = await _methodChannel.invokeMethod('getLocalWorkouts');
    if (result is List) {
      return result.cast<String>();
    }
    return [];
  }

  /// Manually trigger foreground mode (usually handled by app lifecycle observer)
  Future<void> enterForegroundMode() async {
    await _methodChannel.invokeMethod('enterForeground');
  }

  /// Manually trigger background mode (usually handled by app lifecycle observer)
  Future<void> enterBackgroundMode() async {
    await _methodChannel.invokeMethod('enterBackground');
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
