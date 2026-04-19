import 'package:flutter/material.dart';
import 'example_session_manager.dart';

class MonitoringScreen extends StatefulWidget {
  const MonitoringScreen({super.key});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  bool _busy = false;
  String _status = 'Idle — tap a button to control background monitoring.';

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _status = 'Starting…';
    });
    try {
      await ExampleSessionManager.startBackgroundMonitoring();
      setState(() => _status = '✅ Background monitoring started.\nWorkout + sleep observers are armed.');
    } catch (e) {
      setState(() => _status = '❌ Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() {
      _busy = true;
      _status = 'Stopping…';
    });
    try {
      await ExampleSessionManager.stopBackgroundMonitoring();
      setState(() => _status = '🛑 Background monitoring stopped.');
    } catch (e) {
      setState(() => _status = '❌ Error: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Background Monitoring')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Controls the HealthKit background observer registration for workouts and sleep. '
              'The delegate must already be set (user logged in) for start to take effect.',
              style: TextStyle(fontSize: 13, color: Colors.black54),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _busy ? null : _start,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Start Background Monitoring'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _stop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop Background Monitoring'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 32),
            if (_busy) const LinearProgressIndicator(),
            if (!_busy) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: Text(_status, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
