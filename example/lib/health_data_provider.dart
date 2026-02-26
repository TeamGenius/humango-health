import 'dart:async';
import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

class HealthDataProvider extends ChangeNotifier {
  // Maintaining separate manager instances per data type
  final Map<HealthDataType, HealthDataManager> _managers = {
    HealthDataType.steps: HealthDataManager(HealthDataType.steps),
    HealthDataType.heartRate: HealthDataManager(HealthDataType.heartRate),
    HealthDataType.activeCalories: HealthDataManager(HealthDataType.activeCalories),
  };
  
  final Map<HealthDataType, StreamSubscription> _subscriptions = {};

  final Map<HealthDataType, List<HealthDataSample>> _data = {};
  bool _isMonitoring = false;

  Map<HealthDataType, List<HealthDataSample>> get data => _data;
  bool get isMonitoring => _isMonitoring;

  HealthDataProvider() {
    _initLiveStreams();
  }

  void _initLiveStreams() {
    for (var entry in _managers.entries) {
      final type = entry.key;
      final manager = entry.value;

      _subscriptions[type] = manager.healthDataStream.listen((sample) {
        if (!_data.containsKey(type)) {
          _data[type] = [];
        }
        
        bool exists = _data[type]!.any((s) => 
          s.startDate == sample.startDate && 
          s.endDate == sample.endDate &&
          s.value.numericValue == sample.value.numericValue
        );
        
        if (!exists) {
          _data[type]!.insert(0, sample);
          _data[type]!.sort((a, b) => b.endDate.compareTo(a.endDate));
          
          if (_data[type]!.length > 100) {
            _data[type]!.removeLast();
          }
          notifyListeners();
        }
      });
    }
  }

  Future<void> fetchHistoricalData() async {
    final endDate = DateTime.now();
    final startDate = endDate.subtract(const Duration(days: 7));
    
    // Fetch specifically from the Steps manager
    final stepsManager = _managers[HealthDataType.steps]!;
    final results = await stepsManager.readHealthData(
      startDate,
      endDate,
      limit: 50,
    );
    
    for (var sample in results) {
      if (!_data.containsKey(sample.type)) {
        _data[sample.type] = [];
      }
      
      bool exists = _data[sample.type]!.any((s) => 
        s.startDate == sample.startDate && 
        s.endDate == sample.endDate
      );
      
      if (!exists) {
        _data[sample.type]!.add(sample);
      }
    }
    
    // Sort array by recent date first
    if (_data.containsKey(HealthDataType.steps)) {
       _data[HealthDataType.steps]!.sort((a, b) => b.endDate.compareTo(a.endDate));
    }
    
    notifyListeners();
  }

  Future<void> fetchBackgroundData() async {
    bool added = false;
    
    for (var manager in _managers.values) {
      final results = await manager.getLocalHealthData();
      
      for (var sample in results) {
        if (!_data.containsKey(sample.type)) {
          _data[sample.type] = [];
        }
        
        bool exists = _data[sample.type]!.any((s) => 
          s.startDate == sample.startDate && 
          s.endDate == sample.endDate
        );
        
        if (!exists) {
          _data[sample.type]!.add(sample);
          added = true;
        }
      }
    }
    
    if (added) {
      for (var list in _data.values) {
        list.sort((a, b) => b.endDate.compareTo(a.endDate));
      }
      notifyListeners();
    }
  }

  Future<void> toggleMonitoring() async {
    final stepsManager = _managers[HealthDataType.steps]!;

    if (_isMonitoring) {
      await stepsManager.stopMonitoring();
      _isMonitoring = false;
    } else {
      await stepsManager.startMonitoring();
      _isMonitoring = true;
    }
    notifyListeners();
  }
  
  void notifyLifecycleForeground() {
    for (var manager in _managers.values) {
      manager.enterForegroundMode();
    }
  }

  void notifyLifecycleBackground() {
    for (var manager in _managers.values) {
      manager.enterBackgroundMode();
    }
  }
  
  void clearData() {
    _data.clear();
    notifyListeners();
  }
  
  @override
  void dispose() {
    for (var sub in _subscriptions.values) {
      sub.cancel();
    }
    super.dispose();
  }
}
