//
//  sleep_data_manager.dart
//  humango_health
//
//  Dart manager for fetching and monitoring sleep data from Apple HealthKit
//  Supports: one-shot fetch, live streaming (foreground), background observation
//

import 'dart:async';
import 'package:flutter/services.dart';
import '../models/sleep_sample.dart';

/// Manager for fetching and monitoring sleep data from Apple HealthKit.
///
/// Provides access to sleep analysis data including sleep stages
/// (inBed, awake, asleepCore, asleepDeep, asleepREM) with support for:
/// - One-shot data fetch for a configurable time range
/// - Live streaming in foreground (EventChannel)
/// - Background monitoring with UserDefaults storage
///
/// Example usage:
/// ```dart
/// final sleepManager = SleepDataManager();
///
/// // One-shot fetch
/// final response = await sleepManager.getSleepData();
///
/// // Live streaming subscription
/// final subscription = sleepManager.sleepDataStream.listen((event) {
///   if (event is SleepSampleEvent) {
///     print('New sleep sample: ${event.sample.sleepStage}');
///   }
/// });
///
/// // Start monitoring
/// await sleepManager.startMonitoring();
///
/// // Later, stop monitoring
/// await sleepManager.stopMonitoring();
/// subscription.cancel();
/// ```
class SleepDataManager {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.health/sleep',
  );

  static const EventChannel _eventChannel = EventChannel(
    'com.humango.health/sleep/stream',
  );

  /// Stream of sleep data events from iOS.
  /// Events include:
  /// - [SleepSampleEvent]: New sleep sample received
  /// - [SleepSampleDeletedEvent]: Sleep sample was deleted
  Stream<SleepDataEvent> get sleepDataStream {
    return _eventChannel.receiveBroadcastStream().map((event) {
      final map = Map<String, dynamic>.from(event as Map);
      return SleepDataEvent.fromMap(map);
    });
  }

  /// Fetches sleep data from HealthKit for the specified time range.
  ///
  /// **Parameters:**
  /// - [startDate]: Start of the time range (defaults to 24 hours ago)
  /// - [endDate]: End of the time range (defaults to now)
  ///
  /// Returns a [SleepDataResponse] containing all sleep samples and aggregated statistics.
  Future<SleepDataResponse> getSleepData({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final effectiveEndDate = endDate ?? DateTime.now();
    final effectiveStartDate =
        startDate ?? effectiveEndDate.subtract(const Duration(hours: 24));

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getSleepData', {
            'startDate': effectiveStartDate.toIso8601String(),
            'endDate': effectiveEndDate.toIso8601String(),
          });

      if (result != null) {
        final map = Map<String, dynamic>.from(result);
        return SleepDataResponse.fromMap(map);
      }

      return _emptyResponse(effectiveStartDate, effectiveEndDate);
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Unknown error fetching sleep data',
        details: e.details,
      );
    }
  }

  /// Starts monitoring sleep data changes.
  ///
  /// In **foreground**: Uses HKAnchoredObjectQueryDescriptor for live streaming.
  /// Each new sleep sample is pushed to [sleepDataStream].
  ///
  /// In **background**: Uses HKObserverQuery to detect changes and stores
  /// data in UserDefaults. Retrieve with [fetchStoredSleepData].
  ///
  /// Call [enterForeground] / [enterBackground] to switch modes.
  Future<Map<String, dynamic>> startMonitoring({DateTime? startDate}) async {
    final effectiveStartDate =
        startDate ?? DateTime.now().subtract(const Duration(hours: 24));

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'startSleepMonitoring',
        {'startDate': effectiveStartDate.toIso8601String()},
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to start sleep monitoring',
        details: e.details,
      );
    }
  }

  /// Stops monitoring sleep data changes.
  Future<Map<String, dynamic>> stopMonitoring() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'stopSleepMonitoring',
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to stop sleep monitoring',
        details: e.details,
      );
    }
  }

  /// Fetches sleep data that was stored in UserDefaults during background monitoring.
  ///
  /// Returns a [SleepDataResponse] with data collected while the app was in background.
  /// The response includes `storedAt` timestamp indicating when data was last updated.
  Future<SleepDataResponse> fetchStoredSleepData() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'fetchStoredSleepData',
      );

      if (result != null) {
        final map = Map<String, dynamic>.from(result);
        if (map['hasData'] == true) {
          return SleepDataResponse.fromMap(map);
        }
      }

      return _emptyResponse(
        DateTime.now().subtract(const Duration(hours: 24)),
        DateTime.now(),
      );
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to fetch stored sleep data',
        details: e.details,
      );
    }
  }

  /// Clears sleep data stored in UserDefaults.
  Future<void> clearStoredSleepData() async {
    try {
      await _channel.invokeMethod('clearStoredSleepData');
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to clear stored sleep data',
        details: e.details,
      );
    }
  }

  /// Notifies iOS that the app has entered foreground (manual override).
  ///
  /// **Note:** This is typically NOT needed as native iOS handles lifecycle
  /// automatically via `AppLifecycleManager`. Use this only for manual override.
  ///
  /// Switches from background observer to live streaming if monitoring is active.
  Future<void> enterForeground() async {
    try {
      await _channel.invokeMethod('enterSleepForeground');
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to enter foreground mode',
        details: e.details,
      );
    }
  }

  /// Notifies iOS that the app has entered background (manual override).
  ///
  /// **Note:** This is typically NOT needed as native iOS handles lifecycle
  /// automatically via `AppLifecycleManager`. Use this only for manual override.
  ///
  /// Switches from live streaming to background observer if monitoring is active.
  Future<void> enterBackground() async {
    try {
      await _channel.invokeMethod('enterSleepBackground');
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to enter background mode',
        details: e.details,
      );
    }
  }

  SleepDataResponse _emptyResponse(DateTime from, DateTime to) {
    return SleepDataResponse(
      samples: [],
      sampleCount: 0,
      totalSleepSeconds: 0,
      totalSleepMinutes: 0,
      totalSleepHours: 0,
      stageTotals: SleepStageTotals(
        inBedSeconds: 0,
        asleepUnspecifiedSeconds: 0,
        awakeSeconds: 0,
        asleepCoreSeconds: 0,
        asleepDeepSeconds: 0,
        asleepREMSeconds: 0,
      ),
      fetchedFrom: from,
      fetchedTo: to,
      rawJson: {},
    );
  }
}

/// Base class for sleep data streaming events
abstract class SleepDataEvent {
  factory SleepDataEvent.fromMap(Map<String, dynamic> map) {
    final type = map['type'] as String?;
    switch (type) {
      case 'sleepSample':
        return SleepSampleEvent(
          sample: SleepSample.fromMap(
            Map<String, dynamic>.from(map['sample'] as Map),
          ),
        );
      case 'sleepSampleDeleted':
        return SleepSampleDeletedEvent(uuid: map['uuid'] as String);
      default:
        return SleepDataUnknownEvent(rawData: map);
    }
  }
}

/// Event emitted when a new sleep sample is received
class SleepSampleEvent implements SleepDataEvent {
  final SleepSample sample;

  SleepSampleEvent({required this.sample});

  @override
  String toString() =>
      'SleepSampleEvent(${sample.sleepStage}, ${sample.durationMinutes.toStringAsFixed(1)} min)';
}

/// Event emitted when a sleep sample is deleted
class SleepSampleDeletedEvent implements SleepDataEvent {
  final String uuid;

  SleepSampleDeletedEvent({required this.uuid});

  @override
  String toString() => 'SleepSampleDeletedEvent($uuid)';
}

/// Event for unknown event types
class SleepDataUnknownEvent implements SleepDataEvent {
  final Map<String, dynamic> rawData;

  SleepDataUnknownEvent({required this.rawData});

  @override
  String toString() => 'SleepDataUnknownEvent($rawData)';
}

/// Exception thrown when sleep data operations fail
class SleepDataException implements Exception {
  final String code;
  final String message;
  final dynamic details;

  SleepDataException({required this.code, required this.message, this.details});

  @override
  String toString() => 'SleepDataException($code): $message';
}
