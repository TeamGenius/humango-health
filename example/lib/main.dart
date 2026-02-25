import 'package:flutter/material.dart';
import 'package:humango_health/humango_health.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final PermissionManager _permissionManager = PermissionManager();
  StreamSubscription<PermissionResponse>? _permissionSubscription;

  String _statusText = "Not verified";

  // Define the types we want to ask for permissions
  final List<HealthDataType> _readTypes = [
    HealthDataType.workout,
    HealthDataType.heartRate,
    HealthDataType.steps,
    HealthDataType.sleepAnalysis,
    HealthDataType.restingHeartRate,
    HealthDataType.hrv,
  ];

  final List<HealthDataType> _writeTypes = [HealthDataType.workout];

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  @override
  void dispose() {
    _permissionSubscription?.cancel();
    super.dispose();
  }

  void _startListening() {
    // Listen to changes in permission status asynchronously
    _permissionSubscription = _permissionManager
        .listen(_readTypes, _writeTypes)
        .listen(
          (PermissionResponse response) {
            if (mounted) {
              setState(() {
                _statusText = _formatResponse(response);
              });
              
              _checkForDeniedPermissions(response);
            }
          },
          onError: (error) {
            setState(() {
              _statusText = "Stream Error: $error";
            });
          },
        );
  }

  void _checkForDeniedPermissions(PermissionResponse response) {
    // Check if any write permissions were denied
    bool anyDenied = response.writeStatuses.values.any(
      (status) => status == PermissionStatus.denied
    );

    if (anyDenied) {
      _showPermissionDeniedDialog();
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Permissions Required'),
          content: const Text(
            'We noticed that you denied some Health permissions. '
            'To track your training metrics and save workouts, Humango needs access to your Health data.\n\n'
            'Please open Settings, go to Health -> Data Access & Devices -> Humango Health Example, and turn on the switches.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                // Deep link to iOS Settings App
                final Uri url = Uri.parse('app-settings:');
                if (await canLaunchUrl(url)) {
                  await launchUrl(url);
                }
              },
              child: const Text('Open Settings'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _verifyPermissions() async {
    try {
      final PermissionResponse response = await _permissionManager.verify(
        _readTypes,
        _writeTypes,
      );

      if (mounted) {
        setState(() {
          _statusText = "Verified status:\n\n${_formatResponse(response)}";
        });
        _checkForDeniedPermissions(response);
      }
    } catch (e) {
      setState(() {
        _statusText = "Error verifying: $e";
      });
    }
  }

  Future<void> _requestPermissions() async {
    try {
      // Fire-and-forget request
      // iOS will show the Health app permission sheet
      await _permissionManager.request(_readTypes, _writeTypes);

      setState(() {
        _statusText = "Requested permissions. Check Health app popup.";
      });
      // Verification will be captured when the app comes back to foreground
      // natively handled by the event channel Stream.
    } catch (e) {
      setState(() {
        _statusText = "Error requesting permissions: $e";
      });
    }
  }

  String _formatResponse(PermissionResponse response) {
    StringBuffer sb = StringBuffer();
    sb.writeln("--- READ PERMISSIONS ---");
    response.readStatuses.forEach((type, status) {
      sb.writeln("${type.name}: ${status.name}");
    });

    sb.writeln("\n--- WRITE PERMISSIONS ---");
    response.writeStatuses.forEach((type, status) {
      sb.writeln("${type.name}: ${status.name}");
    });

    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Humango Health Permissions')),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton(
                onPressed: _verifyPermissions,
                child: const Text('Verify Current Permissions'),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _requestPermissions,
                child: const Text('Request Permissions'),
              ),
              const SizedBox(height: 24),
              const Text(
                'Status Log:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _statusText,
                      style: const TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
