import 'package:flutter/services.dart';
import '../models/health_data_sample.dart';
import '../models/health_data_type.dart';
import '../models/health_data_read_options.dart';

class HealthDataManager {
  static const MethodChannel _methodChannel = MethodChannel('com.humango.workouts/health');
  static const EventChannel _eventChannel = EventChannel('com.humango.workouts/health/stream');

  final HealthDataType type;
  Stream<HealthDataSample>? _healthDataStream;

  HealthDataManager(this.type);

  /// Stream for real-time health data updates (foreground) for this specific type
  Stream<HealthDataSample> get healthDataStream {
    _healthDataStream ??= _eventChannel.receiveBroadcastStream().map((event) {
      final json = Map<String, dynamic>.from(event);
      return HealthDataSample.fromJson(json);
    }).where((sample) => sample.type == type); // Only yield this manager's type
    
    return _healthDataStream!;
  }

  /// One-shot fetch of historical health data for this specific type
  Future<List<HealthDataSample>> readHealthData(
    DateTime startDate,
    DateTime endDate, {
    int? limit,
  }) async {
    final options = HealthDataReadOptions(
      type: this.type,
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    );

    try {
      final List<dynamic>? results = await _methodChannel.invokeMethod('readHealthData', options.toJson());
      if (results == null) return [];

      return results.map((e) => HealthDataSample.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      print("Error fetching historical data: $e");
      return [];
    }
  }

  /// Start continuous monitoring (foreground + background) for this specific type
  Future<void> startMonitoring({
    DateTime? startDate,
  }) async {
    final args = {
      'type': this.type.identifier,
      'startDate': (startDate ?? DateTime.now()).toIso8601String(),
    };

    await _methodChannel.invokeMethod('startMonitoring', args);
  }

  /// Stop monitoring entirely for this specific type
  Future<void> stopMonitoring() async {
    await _methodChannel.invokeMethod('stopMonitoring', {'type': this.type.identifier});
  }

  /// Get locally stored samples (collected from background wakeups)
  Future<List<HealthDataSample>> getLocalHealthData() async {
    try {
      final List<dynamic>? results = await _methodChannel.invokeMethod('getLocalHealthData');
      if (results == null) return [];

      return results.map((e) => HealthDataSample.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (e) {
      return [];
    }
  }

  /// Called upon AppLifecycleState.resumed
  Future<void> enterForegroundMode() async {
    await _methodChannel.invokeMethod('enterForeground');
  }

  /// Called upon AppLifecycleState.paused
  Future<void> enterBackgroundMode() async {
    await _methodChannel.invokeMethod('enterBackground');
  }
}
