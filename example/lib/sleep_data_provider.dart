import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';

class SleepDataProvider extends ChangeNotifier {
  final SleepDataManager _manager = SleepDataManager();
  
  List<SleepData> _sleepHistory = [];
  SleepData? _currentRecord;
  
  bool _isLoading = false;

  List<SleepData> get sleepHistory => _sleepHistory;
  SleepData? get currentRecord => _currentRecord;
  bool get isLoading => _isLoading;

  Future<void> fetchSleepHistory() async {
    _isLoading = true;
    notifyListeners();
    
    _sleepHistory = await _manager.readSleepData(pastDays: 7);
    
    _isLoading = false;
    notifyListeners();
  }

  Future<void> fetchCurrentRecord() async {
    _isLoading = true;
    notifyListeners();
    
    _currentRecord = await _manager.getCurrentRecord();
    
    _isLoading = false;
    notifyListeners();
  }
  
  void clearData() {
    _sleepHistory.clear();
    _currentRecord = null;
    notifyListeners();
  }
}
