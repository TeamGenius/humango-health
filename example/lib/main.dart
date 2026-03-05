import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'health_permissions_provider.dart';
import 'workout_push_screen.dart' as workouts;
import 'workout_read_screen.dart' as readworkouts;
import 'sleep_data_screen.dart' as sleep;
import 'health_metrics_screen.dart';
import 'package:humango_health/humango_health.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => HealthPermissionsProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Empty lifecycle hook since HealthDataProvider was removed
  }

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HealthPermissionsScreen());
  }
}

class HealthPermissionsScreen extends StatelessWidget {
  const HealthPermissionsScreen({super.key});

  void _showPermissionDeniedDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Permissions Required'),
          content: const Text(
            'We noticed that you denied some Health permissions. '
            'To track your training metrics and save workouts, Humango needs access to your Health data.\n\n'
            'Please open Settings, go to Health -> Data Access & Devices -> Humango Health Example, and turn on the switches.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Humango Health Permissions')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Consumer<HealthPermissionsProvider>(
          builder: (context, provider, child) {
            // Check for denied and optionally show dialog
            // NOTE: In production you might want to debounce this or
            // show it based on explicit user action rather than on every rebuild.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (provider.hasAnyDenied) {
                // To avoid spamming dialogs, you might use a shared preference or state flag.
                // For this example we just log it to avoid endless loops on rebuilds.
                print("Permissions Denied Detected!");
              }
            });

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    await provider.verifyPermissions();
                    if (provider.hasAnyDenied && context.mounted) {
                      _showPermissionDeniedDialog(context);
                    }
                  },
                  child: const Text('Verify Current Permissions'),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => provider.requestPermissions(),
                  child: const Text('Request Permissions'),
                ),
                if (provider.streamError.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    provider.streamError,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
                const SizedBox(height: 24),

                // Header Status
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'All Authorized:',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    Icon(
                      provider.isAuthorized ? Icons.check_circle : Icons.cancel,
                      color: provider.isAuthorized ? Colors.green : Colors.red,
                    ),
                  ],
                ),
                const Divider(),

                // Detailed Status List
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Permission Details:',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[100],
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const _AppTabsScreen(),
                          ),
                        );
                      },
                      child: const Text('Explore Integrations →'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: provider.statuses.isEmpty
                      ? const Center(child: Text("No statuses loaded yet."))
                      : ListView.builder(
                          itemCount: provider.statuses.length,
                          itemBuilder: (context, index) {
                            final entry = provider.statuses.entries.elementAt(
                              index,
                            );
                            final type = entry.key;
                            final status = entry.value;

                            Color statusColor = Colors.grey;
                            if (status == PermissionStatus.authorized) {
                              statusColor = Colors.green;
                            } else if (status == PermissionStatus.denied) {
                              statusColor = Colors.red;
                            } else if (status == PermissionStatus.noData) {
                              statusColor = Colors.blue;
                            }

                            return ListTile(
                              title: Text(type.name),
                              trailing: Chip(
                                label: Text(
                                  status.name.toUpperCase(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                backgroundColor: statusColor,
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AppTabsScreen extends StatefulWidget {
  const _AppTabsScreen();

  @override
  State<_AppTabsScreen> createState() => _AppTabsScreenState();
}

class _AppTabsScreenState extends State<_AppTabsScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const workouts.WorkoutPushScreen(),
    const readworkouts.WorkoutReadScreen(),
    const sleep.SleepDataScreen(),
    const HealthMetricsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.sports_score),
            label: 'Push',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.sync), label: 'Read'),
          BottomNavigationBarItem(icon: Icon(Icons.bedtime), label: 'Sleep'),
          BottomNavigationBarItem(
            icon: Icon(Icons.monitor_heart),
            label: 'Metrics',
          ),
        ],
      ),
    );
  }
}
