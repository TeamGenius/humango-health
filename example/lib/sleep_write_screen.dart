import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SleepWriteScreen extends StatefulWidget {
  const SleepWriteScreen({super.key});

  @override
  State<SleepWriteScreen> createState() => _SleepWriteScreenState();
}

class _SleepWriteScreenState extends State<SleepWriteScreen> {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.example/addSleep',
  );

  static const List<String> _sleepStages = [
    'asleepUnspecified',
    'asleepCore',
    'asleepDeep',
    'asleepREM',
  ];

  DateTime _startDateTime = DateTime.now().subtract(const Duration(hours: 8));
  DateTime _endDateTime = DateTime.now();
  String _selectedStage = _sleepStages.first;

  bool _isSaving = false;
  String _status = 'Select time range and stage, then save to HealthKit.';
  bool _isError = false;

  Future<void> _pickDateTime({required bool isStart}) async {
    final initial = isStart ? _startDateTime : _endDateTime;
    final now = DateTime.now();

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 730)),
      lastDate: now.add(const Duration(days: 1)),
      helpText: isStart ? 'Select start date' : 'Select end date',
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: isStart ? 'Select start time' : 'Select end time',
    );
    if (pickedTime == null || !mounted) return;

    final combined = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );

    setState(() {
      if (isStart) {
        _startDateTime = combined;
      } else {
        _endDateTime = combined;
      }
      _status = 'Ready to save.';
      _isError = false;
    });
  }

  bool _validateInput() {
    if (!_endDateTime.isAfter(_startDateTime)) {
      setState(() {
        _isError = true;
        _status = 'End time must be after start time.';
      });
      return false;
    }

    final duration = _endDateTime.difference(_startDateTime);
    if (duration > const Duration(days: 2)) {
      setState(() {
        _isError = true;
        _status = 'Please choose a duration of 48 hours or less for testing.';
      });
      return false;
    }

    return true;
  }

  Future<void> _saveSleepSample() async {
    if (!_validateInput()) return;

    setState(() {
      _isSaving = true;
      _isError = false;
      _status = 'Saving sleep sample to HealthKit...';
    });

    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('addSleepSample', {
            'startDate': _startDateTime.toUtc().toIso8601String(),
            'endDate': _endDateTime.toUtc().toIso8601String(),
            'sleepStage': _selectedStage,
          });

      final uuid = result?['uuid']?.toString() ?? 'n/a';
      setState(() {
        _status = 'Saved successfully. UUID: $uuid';
        _isError = false;
      });
    } on PlatformException catch (e) {
      setState(() {
        _status = '${e.code}: ${e.message ?? 'Unknown platform error'}';
        _isError = true;
      });
    } catch (e) {
      setState(() {
        _status = e.toString();
        _isError = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  String _fmtDateTime(DateTime dt) {
    final local = dt;
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final min = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$mm-$dd $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Write Sleep to Apple Health',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'This screen writes an HKCategorySample for sleepAnalysis using an example-only native channel.',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Start',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(child: Text(_fmtDateTime(_startDateTime))),
                        OutlinedButton.icon(
                          onPressed: _isSaving
                              ? null
                              : () => _pickDateTime(isStart: true),
                          icon: const Icon(Icons.edit_calendar, size: 18),
                          label: const Text('Select'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'End',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(child: Text(_fmtDateTime(_endDateTime))),
                        OutlinedButton.icon(
                          onPressed: _isSaving
                              ? null
                              : () => _pickDateTime(isStart: false),
                          icon: const Icon(Icons.edit_calendar, size: 18),
                          label: const Text('Select'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Sleep Type',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    InputDecorator(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedStage,
                          isExpanded: true,
                          items: _sleepStages
                              .map(
                                (stage) => DropdownMenuItem(
                                  value: stage,
                                  child: Text(stage),
                                ),
                              )
                              .toList(),
                          onChanged: _isSaving
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setState(() {
                                    _selectedStage = value;
                                  });
                                },
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isSaving ? null : _saveSleepSample,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.save),
                        label: Text(
                          _isSaving ? 'Saving...' : 'Save to HealthKit',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              color: _isError ? Colors.red.shade50 : Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _isError ? Icons.error_outline : Icons.info_outline,
                      color: _isError ? Colors.red : Colors.green.shade800,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status,
                        style: TextStyle(
                          color: _isError
                              ? Colors.red.shade700
                              : Colors.green.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
