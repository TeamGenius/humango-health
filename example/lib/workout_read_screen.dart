import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';
import 'package:flutter/foundation.dart';

class WorkoutReadScreen extends StatefulWidget {
  const WorkoutReadScreen({super.key});

  @override
  State<WorkoutReadScreen> createState() => _WorkoutReadScreenState();
}

class _WorkoutReadScreenState extends State<WorkoutReadScreen> {
  final WorkoutReadManager _readManager = WorkoutReadManager();
  bool _isLoading = false;
  String _statusMessage = 'Idle';
  List<WorkoutData> _fetchedWorkouts = [];

  /// Hold a stable reference so StreamBuilder does not recreate the
  /// native EventChannel stream on every rebuild.
  late final Stream<String> _workoutStream;

  @override
  void initState() {
    super.initState();
    _workoutStream = _readManager.workoutStream;
  }

  Future<void> _fetchPastWorkouts() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Fetching workouts...';
      _fetchedWorkouts = [];
    });

    try {
      final now = DateTime.now();
      // Fetch past 7 days of workouts
      final rawJsons = await _readManager.readWorkouts(
        now.subtract(const Duration(days: 7)),
      );
      print("Raw json $rawJsons");

      final parsed = rawJsons
          .map((e) => WorkoutData.fromJson(jsonDecode(e)))
          .toList();

      setState(() {
        _statusMessage = 'Successfully fetched ${parsed.length} workouts.';
        _fetchedWorkouts = parsed;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error fetching workouts: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _startMonitoring() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Starting monitoring...';
    });

    try {
      final now = DateTime.now();
      // Monitor from 1 hour ago onwards (open-ended)
      await _readManager.startMonitoring(
        now.subtract(const Duration(hours: 1)),
      );

      // We route background deliveries to local storage for test
      await _readManager.configureBackgroundDelivery(
        BackgroundDeliveryConfig(mode: BackgroundDeliveryMode.localStorage),
      );

      setState(() {
        _statusMessage = 'Monitoring active. Waiting for stream events...';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Failed to start monitoring: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _stopMonitoring() async {
    try {
      await _readManager.stopMonitoring();
      setState(() {
        _statusMessage = 'Monitoring stopped.';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error stopping: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Read Workouts Test')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _isLoading ? null : _fetchPastWorkouts,
              child: const Text('Fetch Past 7 Days'),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _startMonitoring,
                    child: const Text('Start Livestream'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _stopMonitoring,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade100,
                    ),
                    child: const Text('Stop Livestream'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Status: $_statusMessage',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            // Stream Builder for live updates
            StreamBuilder<String>(
              stream: _workoutStream,
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  debugPrint("Snapshot data : ${snapshot.data}");
                  return Container(
                    padding: const EdgeInsets.all(8),
                    color: Colors.green.shade50,
                    child: Text(
                      'Live Event Received: ${snapshot.data!.substring(0, 100)}...',
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            const Divider(),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: _fetchedWorkouts.length,
                      itemBuilder: (context, index) {
                        final w = _fetchedWorkouts[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          child: ListTile(
                            title: Text(
                              '${w.activityType} - ${w.duration.toStringAsFixed(1)}s',
                            ),
                            subtitle: Text(
                              'Start: ${w.startTime.toLocal()}\nDistance: ${w.distance ?? 0}',
                            ),
                            trailing: Text('${w.quantitySeries.length} Series'),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
