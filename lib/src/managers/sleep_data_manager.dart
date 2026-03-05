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
import '../models/sleep_background_delivery_config.dart';

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

  /// Configures the sleep session freeze window and detection parameters.
  ///
  /// The freeze window defines the time period (local time) during which
  /// sleep data is accumulated without declaring session end.
  /// Default: 12:00 AM → 12:00 PM.
  ///
  /// **Parameters:**
  /// - [freezeWindowStartHour]: Start hour in local time (0-23). Default: 0 (midnight)
  /// - [freezeWindowEndHour]: End hour in local time (0-23). Default: 12 (noon)
  /// - [minimumSleepMinutes]: Minimum sleep before session can end. Default: 240 (4 hrs)
  /// - [stalenessThresholdMinutes]: Minutes of no data before declaring stale. Default: 60
  /// - [deepSleepAbsenceWindowMinutes]: No deep sleep in this window = late sleep. Default: 90
  ///
  /// Call this before [startMonitoring] to customize detection behavior.
  Future<Map<String, dynamic>> configureSleepSession({
    int freezeWindowStartHour = 0,
    int freezeWindowEndHour = 12,
    double minimumSleepMinutes = 240,
    double stalenessThresholdMinutes = 60,
    double deepSleepAbsenceWindowMinutes = 90,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('configureSleepSession', {
            'freezeWindowStartHour': freezeWindowStartHour,
            'freezeWindowEndHour': freezeWindowEndHour,
            'minimumSleepMinutes': minimumSleepMinutes,
            'stalenessThresholdMinutes': stalenessThresholdMinutes,
            'deepSleepAbsenceWindowMinutes': deepSleepAbsenceWindowMinutes,
          });
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to configure sleep session',
        details: e.details,
      );
    }
  }

  /// Returns the current sleep session status.
  ///
  /// Includes:
  /// - `status`: "active", "ended", or "freeze_expired"
  /// - `isInFreezeWindow`: Whether currently in the freeze window
  /// - `segmentCount`: Number of accumulated sleep segments
  /// - `totalSleepMinutes`: Total sleep time accumulated
  /// - `hasRecentDeepSleep`: Whether deep sleep appeared recently
  /// - `isFinalized`: Whether the session has been finalized
  Future<Map<String, dynamic>> getSleepSessionStatus() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getSleepSessionStatus',
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to get sleep session status',
        details: e.details,
      );
    }
  }

  /// Resets the current sleep session state.
  ///
  /// Call this after processing a finalized session to start fresh
  /// for the next night's sleep.
  Future<Map<String, dynamic>> resetSleepSession() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'resetSleepSession',
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to reset sleep session',
        details: e.details,
      );
    }
  }

  /// Configures background delivery mode for sleep session data.
  ///
  /// **API mode** (`SleepBackgroundDeliveryMode.api`):
  /// - Finalized sleep sessions are POSTed directly to the configured API endpoint.
  /// - Both foreground (`HKAnchoredObjectQueryDescriptor`) and background (`HKObserverQuery`)
  ///   run normally — samples accumulate into session state instead of being pushed to EventChannel.
  /// - When the session ends (multi-factor scoring), the complete session is POSTed to your API.
  /// - The [sleepDataStream] will still emit `sleepSessionEnded` events for awareness.
  ///
  /// **Local storage mode** (`SleepBackgroundDeliveryMode.localStorage`):
  /// - Default behavior: foreground uses EventChannel streaming,
  ///   background stores data in UserDefaults.
  ///
  /// Call this before [startMonitoring] for best results. If called while
  /// monitoring is active, the mode switch takes effect immediately.
  ///
  /// Example:
  /// ```dart
  /// await sleepManager.configureSleepBackgroundDelivery(
  ///   SleepBackgroundDeliveryConfig(
  ///     mode: SleepBackgroundDeliveryMode.api,
  ///     apiURL: 'https://api.example.com/sleep-sessions',
  ///     headers: {'Authorization': 'Bearer token123'},
  ///   ),
  /// );
  /// ```
  Future<Map<String, dynamic>> configureSleepBackgroundDelivery(
    SleepBackgroundDeliveryConfig config,
  ) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'configureSleepBackgroundDelivery',
        config.toJson(),
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to configure sleep background delivery',
        details: e.details,
      );
    }
  }

  /// Retrieves and clears locally stored sleep sessions.
  ///
  /// When in `localStorage` mode and the app was in background,
  /// finalized sleep sessions are stored locally. Call this method
  /// after the app becomes active to retrieve them.
  ///
  /// Returns a list of JSON strings, each representing a finalized sleep session.
  /// The local storage is cleared after retrieval.
  Future<List<String>> getLocalSleepSessions() async {
    try {
      final result = await _channel.invokeMethod('getLocalSleepSessions');
      if (result is List) {
        return result.cast<String>();
      }
      return [];
    } on PlatformException catch (e) {
      throw SleepDataException(
        code: e.code,
        message: e.message ?? 'Failed to get local sleep sessions',
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
      case 'sleepSessionEnded':
        return SleepSessionEndedEvent(
          reason: map['reason'] as String? ?? 'unknown',
          segmentCount: map['segmentCount'] as int? ?? 0,
          totalSleepMinutes:
              (map['totalSleepMinutes'] as num?)?.toDouble() ?? 0,
          totalAwakeMinutes:
              (map['totalAwakeMinutes'] as num?)?.toDouble() ?? 0,
          sessionStartDate: map['sessionStartDate'] as String?,
          latestSegmentEndDate: map['latestSegmentEndDate'] as String?,
          finalizedAt: map['finalizedAt'] as String?,
        );
      case 'sleepSessionDelivered':
        return SleepSessionDeliveredEvent(
          sessionId: map['sessionId'] as String? ?? '',
          data: map['data'] as String? ?? '',
        );
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

/// Event emitted when a sleep session has ended.
///
/// This is triggered by the freeze-window-aware session detector when:
/// - Multi-factor scoring detects sleep has ended (during freeze window), OR
/// - The freeze window expires (12:00 PM) with accumulated data
///
/// After receiving this event, call [SleepDataManager.fetchStoredSleepData]
/// to get the full session data, then [SleepDataManager.resetSleepSession]
/// to prepare for the next night.
class SleepSessionEndedEvent implements SleepDataEvent {
  /// Why the session was declared ended
  final String reason;

  /// Number of sleep segments in the session
  final int segmentCount;

  /// Total actual sleep time (excluding awake/inBed) in minutes
  final double totalSleepMinutes;

  /// Total awake time within the sleep session in minutes
  final double totalAwakeMinutes;

  /// ISO8601 start of the first segment
  final String? sessionStartDate;

  /// ISO8601 end of the last segment
  final String? latestSegmentEndDate;

  /// ISO8601 timestamp when the session was finalized
  final String? finalizedAt;

  SleepSessionEndedEvent({
    required this.reason,
    required this.segmentCount,
    required this.totalSleepMinutes,
    required this.totalAwakeMinutes,
    this.sessionStartDate,
    this.latestSegmentEndDate,
    this.finalizedAt,
  });

  @override
  String toString() =>
      'SleepSessionEndedEvent(reason=$reason, segments=$segmentCount, '
      'sleep=${totalSleepMinutes.toStringAsFixed(0)}m, '
      'awake=${totalAwakeMinutes.toStringAsFixed(0)}m)';
}

/// Event emitted when a sleep session has been delivered via localStorage mode.
///
/// This contains the full session JSON data as a string, which can be parsed
/// on the Dart side. Only emitted in `localStorage` delivery mode.
class SleepSessionDeliveredEvent implements SleepDataEvent {
  /// Unique session identifier (typically the session start date)
  final String sessionId;

  /// Full sleep session data as a JSON string
  final String data;

  SleepSessionDeliveredEvent({required this.sessionId, required this.data});

  @override
  String toString() => 'SleepSessionDeliveredEvent(sessionId=$sessionId)';
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
