import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AddSleepScreen extends StatefulWidget {
  const AddSleepScreen({super.key});

  @override
  State<AddSleepScreen> createState() => _AddSleepScreenState();
}

class _AddSleepScreenState extends State<AddSleepScreen> {
  static const MethodChannel _channel = MethodChannel(
    'com.humango.example/addSleep',
  );

  late DateTime _startDateTime;
  late DateTime _endDateTime;
  bool _isSaving = false;
  String? _status;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _endDateTime = now;
    _startDateTime = now.subtract(const Duration(hours: 8));
  }

  Future<void> _pickStartDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _startDateTime,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Select sleep start date',
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_startDateTime),
      helpText: 'Select sleep start time',
    );
    if (pickedTime == null || !mounted) return;

    setState(() {
      _startDateTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
      _status = null;
    });
  }

  Future<void> _pickEndDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _endDateTime,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: 'Select sleep end date',
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_endDateTime),
      helpText: 'Select sleep end time',
    );
    if (pickedTime == null || !mounted) return;

    setState(() {
      _endDateTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
      _status = null;
    });
  }

  String? _validate() {
    if (!_endDateTime.isAfter(_startDateTime)) {
      return 'End date/time must be later than start date/time.';
    }
    return null;
  }

  Future<void> _addSleepSample() async {
    final validationError = _validate();
    if (validationError != null) {
      setState(() {
        _status = validationError;
        _isError = true;
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _status = null;
      _isError = false;
    });

    try {
      final response = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'addSleepSample',
        {
          'startDate': _startDateTime.toUtc().toIso8601String(),
          'endDate': _endDateTime.toUtc().toIso8601String(),
        },
      );

      final sampleUuid = response?['sampleUuid']?.toString() ?? 'unknown';

      setState(() {
        _status = 'Sleep sample saved to Apple Health. UUID: $sampleUuid';
        _isError = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sleep sample successfully added to Apple Health.'),
          ),
        );
      }
    } on PlatformException catch (e) {
      setState(() {
        _status = 'Save failed (${e.code}): ${e.message ?? 'Unknown error'}';
        _isError = true;
      });
    } catch (e) {
      setState(() {
        _status = 'Save failed: $e';
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

  @override
  Widget build(BuildContext context) {
    final validationError = _validate();

    return Scaffold(
      appBar: AppBar(title: const Text('Add Sleep to Apple Health')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Create Sleep Sample',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This writes one sleep sample with value Asleep Unspecified directly to Apple Health.',
                    style: TextStyle(color: Colors.grey[700]),
                  ),
                  const SizedBox(height: 16),
                  _DateTimeRow(
                    label: 'Start',
                    dateTime: _startDateTime,
                    onTap: _pickStartDateTime,
                    icon: Icons.bedtime,
                  ),
                  const SizedBox(height: 12),
                  _DateTimeRow(
                    label: 'End',
                    dateTime: _endDateTime,
                    onTap: _pickEndDateTime,
                    icon: Icons.alarm,
                  ),
                  if (validationError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      validationError,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isSaving ? null : _addSleepSample,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.add),
                      label: Text(_isSaving ? 'Saving...' : 'Add Sleep Sample'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_status != null)
            Card(
              color: _isError ? Colors.red[50] : Colors.green[50],
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _isError ? Icons.error_outline : Icons.check_circle_outline,
                      color: _isError ? Colors.red[700] : Colors.green[700],
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status!,
                        style: TextStyle(
                          color: _isError ? Colors.red[800] : Colors.green[800],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DateTimeRow extends StatelessWidget {
  final String label;
  final DateTime dateTime;
  final VoidCallback onTap;
  final IconData icon;

  const _DateTimeRow({
    required this.label,
    required this.dateTime,
    required this.onTap,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final local = dateTime.toLocal();
    final formatted =
        '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(formatted),
      trailing: const Icon(Icons.edit_calendar),
      onTap: onTap,
    );
  }
}
