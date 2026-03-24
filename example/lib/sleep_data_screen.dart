import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:humango_health/humango_health.dart';
import 'health_sync_coordinator.dart';

class SleepDataScreen extends StatefulWidget {
  const SleepDataScreen({super.key});

  @override
  State<SleepDataScreen> createState() => _SleepDataScreenState();
}

class _SleepDataScreenState extends State<SleepDataScreen>
    with WidgetsBindingObserver {
  SleepDataManager get _sleepManager =>
      context.read<HealthSyncCoordinator>().sleep;

  SleepDataResponse? _sleepData;
  bool _isLoading = false;
  String? _error;

  // Date range selection
  String _selectedRange = 'Last 24 hours';
  DateTime? _customStartDate;
  DateTime? _customEndDate;

  // Live monitoring state
  bool _isMonitoring = false;

  // ── Background payloads (drained from UserDefaults on app resume) ─────────
  // Background HKObserverQuery fires while Flutter is suspended — EventChannel
  // events are lost. Instead, HealthQueueObserver (Runner/iOS native) watches
  // UserDefaults via KVO and posts a local notification. Flutter drains the
  // queue via getLocalSleepSessions() when the app resumes (foreground).
  final List<Map<String, dynamic>> _backgroundPayloads = [];
  int _bgPayloadCount = 0;

  // ── Calculate sleep payload state ─────────────────────────────────────────
  bool _isCalcLoading = false;
  Map<String, dynamic>? _calcPayload;
  String? _calcError;

  // ── Test Setup ────────────────────────────────────────────────────────────
  final _userIdController = TextEditingController(text: 'test-user-001');

  /// Athlete ID for POST /sleep/{athleteId}. Saved to UserDefaults key
  /// 'flutter.athlete_id' so native SleepUploadService can also read it.
  final _athleteIdController = TextEditingController();

  /// Optional Bearer token written to UserDefaults key 'flutter.access_token'.
  final _accessTokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchSleepData();
    });
  }

  /// Called by Flutter when the app returns to foreground.
  /// This is the correct moment to drain UserDefaults — native HealthQueueObserver
  /// has already handled the background notification; now Flutter reads the queue.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _drainBackgroundPayloads();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isMonitoring) {
      _sleepManager.stopMonitoring();
    }
    _userIdController.dispose();
    _athleteIdController.dispose();
    _accessTokenController.dispose();
    super.dispose();
  }

  // ── Background payload drain + upload ───────────────────────────────────

  static const _apiBase = 'humango-api-629346406456.us-central1.run.app';

  /// Drains both UserDefaults queues written by the native layer:
  ///
  /// Drains `sleepPendingLocal` — sessions the native SleepUploadService
  /// didn't yet upload (no credentials at fire time, network failure, etc.).
  /// If the native layer already consumed them all, this returns empty and is
  /// a no-op. Upload responsibility stays in the client app, not the plugin.
  Future<void> _drainBackgroundPayloads() async {
    try {
      final pending = await _sleepManager.getLocalSleepSessions();
      if (pending.isEmpty || !mounted) return;

      setState(() {
        _backgroundPayloads.insertAll(0, _decodeSessions(pending));
        _bgPayloadCount += pending.length;
      });

      final athleteId = _athleteIdController.text.trim();
      if (athleteId.isNotEmpty) {
        await _saveCredentials();
        await _uploadSleepSessions(pending, athleteId);
      } else {
        debugPrint(
          '🛏️ [SleepScreen] pending sessions — set Athlete ID to upload',
        );
      }
    } catch (e) {
      debugPrint('🛏️ [SleepScreen] _drainBackgroundPayloads error: $e');
    }
  }

  List<Map<String, dynamic>> _decodeSessions(List<String> sessions) {
    return sessions.map((s) {
      try {
        final v = jsonDecode(s);
        if (v is Map) return Map<String, dynamic>.from(v);
      } catch (_) {}
      return <String, dynamic>{'raw': s};
    }).toList();
  }

  /// Writes athleteId + accessToken to UserDefaults via the session channel so
  /// the native SleepUploadService can read them during background execution.
  Future<void> _saveCredentials() async {
    const channel = MethodChannel('com.humango.health/session');
    try {
      await channel.invokeMethod('saveCredentials', {
        'athleteId': _athleteIdController.text.trim(),
        'accessToken': _accessTokenController.text.trim(),
      });
    } catch (e) {
      // Channel may not expose this method yet; the native SleepUploadService
      // reads from UserDefaults directly once the keys are written by any means.
      debugPrint(
        '🛏️ [SleepScreen] saveCredentials channel error (non-fatal): $e',
      );
    }
  }

  Future<void> _uploadSleepSessions(
    List<String> sessions,
    String athleteId,
  ) async {
    final uri = Uri.https(_apiBase, '/sleep/$athleteId');
    final token = _accessTokenController.text.trim();
    int uploaded = 0;

    for (final json in sessions) {
      try {
        final client = HttpClient();
        final request = await client.postUrl(uri);
        request.headers.set('Content-Type', 'application/json');
        if (token.isNotEmpty) {
          request.headers.set('Authorization', 'Bearer $token');
        }
        request.write(json);
        final response = await request.close();
        await response.drain<void>();
        client.close();
        if (response.statusCode >= 200 && response.statusCode < 300) {
          uploaded++;
          debugPrint(
            '🛏️ [SleepScreen] ✅ session uploaded (HTTP ${response.statusCode})',
          );
        } else {
          debugPrint(
            '🛏️ [SleepScreen] ⚠️ server returned HTTP ${response.statusCode}',
          );
        }
      } catch (e) {
        debugPrint('🛏️ [SleepScreen] upload error: $e');
      }
    }

    if (mounted && uploaded > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🛏️ $uploaded sleep session(s) uploaded to Humango'),
          backgroundColor: Colors.teal,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ── Test helpers ─────────────────────────────────────────────────────────

  Future<void> _setUserLoggedIn(bool loggedIn) async {
    final userId = _userIdController.text.trim();
    final coordinator = context.read<HealthSyncCoordinator>();
    await coordinator.setUserLoggedIn(
      loggedIn: loggedIn,
      userId: userId.isNotEmpty ? userId : null,
      configureBackground: loggedIn,
    );
  }

  /// Idempotent; same as after login.
  Future<void> _configureBgDelivery() async {
    await context
        .read<HealthSyncCoordinator>()
        .ensureBackgroundDeliveryConfigured();
  }

  /// Calls the group-based sleep payload calculation and updates local state.
  Future<void> _runCalculateSleepPayload() async {
    setState(() {
      _isCalcLoading = true;
      _calcError = null;
      _calcPayload = null;
    });
    try {
      final payload = await _sleepManager.calculateSleepPayload(
        startDate: _getStartDate(),
        endDate: _getEndDate(),
      );
      setState(() {
        _calcPayload = payload;
        _isCalcLoading = false;
      });
    } on SleepDataException catch (e) {
      setState(() {
        _calcError = '${e.code}: ${e.message}';
        _isCalcLoading = false;
      });
    } catch (e) {
      setState(() {
        _calcError = e.toString();
        _isCalcLoading = false;
      });
    }
  }

  DateTime _getStartDate() {
    final now = DateTime.now();
    switch (_selectedRange) {
      case 'Last 24 hours':
        return now.subtract(const Duration(hours: 24));
      case 'Last 3 days':
        return now.subtract(const Duration(days: 3));
      case 'Last 7 days':
        return now.subtract(const Duration(days: 7));
      case 'Custom':
        return _customStartDate ?? now.subtract(const Duration(hours: 24));
      default:
        return now.subtract(const Duration(hours: 24));
    }
  }

  DateTime _getEndDate() {
    if (_selectedRange == 'Custom' && _customEndDate != null) {
      return _customEndDate!;
    }
    return DateTime.now();
  }

  Future<void> _fetchSleepData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _sleepManager.getSleepData(
        startDate: _getStartDate(),
        endDate: _getEndDate(),
      );
      setState(() {
        _sleepData = response;
        _isLoading = false;
      });
    } on SleepDataException catch (e) {
      print(e);
      setState(() {
        _error = '${e.code}: ${e.message}';
        _isLoading = false;
      });
    } catch (e) {
      print(e);
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _selectCustomDateRange() async {
    final now = DateTime.now();
    final pickedStart = await showDatePicker(
      context: context,
      initialDate: _customStartDate ?? now.subtract(const Duration(days: 1)),
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      helpText: 'Select start date',
    );

    if (pickedStart == null || !mounted) return;

    final pickedEnd = await showDatePicker(
      context: context,
      initialDate: _customEndDate ?? now,
      firstDate: pickedStart,
      lastDate: now,
      helpText: 'Select end date',
    );

    if (pickedEnd == null || !mounted) return;

    setState(() {
      _customStartDate = pickedStart;
      _customEndDate = pickedEnd.add(
        const Duration(hours: 23, minutes: 59, seconds: 59),
      );
      _selectedRange = 'Custom';
    });
    _fetchSleepData();
  }

  // MARK: - Live Monitoring

  Future<void> _toggleMonitoring() async {
    if (_isMonitoring) {
      await _stopMonitoring();
    } else {
      await _startMonitoring();
    }
  }

  Future<void> _startMonitoring() async {
    try {
      final result = await _sleepManager.startMonitoring(
        startDate: _getStartDate(),
      );

      setState(() {
        _isMonitoring = true;
      });

      print('🛏️ Started monitoring: $result');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Monitoring started')));
      }
    } catch (e) {
      print('🛏️ Error starting monitoring: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _stopMonitoring() async {
    try {
      await _sleepManager.stopMonitoring();

      setState(() {
        _isMonitoring = false;
      });

      print('🛏️ Stopped monitoring');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Monitoring stopped')));
      }
    } catch (e) {
      print('🛏️ Error stopping monitoring: $e');
    }
  }

  Future<void> _fetchStoredData() async {
    try {
      final storedData = await _sleepManager.fetchStoredSleepData();
      setState(() {
        _sleepData = storedData;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Loaded ${storedData.sampleCount} stored samples'),
          ),
        );
      }
    } catch (e) {
      print('🛏️ Error fetching stored data: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sleep Data'),
        actions: [
          // Monitoring toggle
          IconButton(
            icon: Icon(
              _isMonitoring ? Icons.stop_circle : Icons.play_circle,
              color: _isMonitoring ? Colors.red : null,
            ),
            onPressed: _toggleMonitoring,
            tooltip: _isMonitoring ? 'Stop monitoring' : 'Start monitoring',
          ),
          // Fetch stored data (from background)
          IconButton(
            icon: const Icon(Icons.storage),
            onPressed: _fetchStoredData,
            tooltip: 'Fetch stored data',
          ),
          // Calculate group-based sleep payload
          IconButton(
            icon: _isCalcLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.calculate),
            onPressed: _isCalcLoading ? null : _runCalculateSleepPayload,
            tooltip: 'Calculate sleep payload',
          ),
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: _selectCustomDateRange,
            tooltip: 'Select custom date range',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchSleepData,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTestSetupCard(),
          _buildDateRangeSelector(),
          if (_isMonitoring) _buildMonitoringBanner(),
          if (_backgroundPayloads.isNotEmpty) _buildBackgroundPayloadsCard(),
          _buildCalculatePayloadSection(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // ── Test Setup Card ───────────────────────────────────────────────────────

  Widget _buildTestSetupCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      color: Colors.indigo.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🧪 Session + local sleep/workout delivery',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _userIdController,
              decoration: const InputDecoration(
                labelText: 'Test User ID',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.login, size: 16),
                    label: const Text('Set Logged In'),
                    onPressed: () => _setUserLoggedIn(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.logout, size: 16),
                    label: const Text('Set Logged Out'),
                    onPressed: () => _setUserLoggedIn(false),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                  ),
                ),
              ],
            ),
            Consumer<HealthSyncCoordinator>(
              builder: (context, coordinator, _) {
                final session = coordinator.sessionStatus;
                final bg = coordinator.backgroundDeliveryStatus;
                final err = coordinator.lastError;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (session != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        session,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.indigo,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(
                          Icons.settings_backup_restore,
                          size: 16,
                        ),
                        label: const Text('Re-apply delivery arm (idempotent)'),
                        onPressed: _configureBgDelivery,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                      ),
                    ),
                    if (bg != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        bg,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.indigo,
                        ),
                      ),
                    ],
                    if (err != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        err,
                        style: const TextStyle(fontSize: 11, color: Colors.red),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      'Plugin stores sleep sessions locally — upload from your app.',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            const Text(
              '☁️ Upload credentials (POST /sleep/{athleteId})',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _athleteIdController,
              decoration: const InputDecoration(
                labelText: 'Athlete ID',
                hintText: 'e.g. 12345',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              style: const TextStyle(fontSize: 13),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _accessTokenController,
              decoration: const InputDecoration(
                labelText: 'Access Token (optional)',
                hintText: 'Bearer token',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              style: const TextStyle(fontSize: 13),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.cloud_upload, size: 16),
                label: const Text('Save & sync credentials to native layer'),
                onPressed: _saveCredentials,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.teal,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Credentials are passed to native SleepUploadService via UserDefaults (flutter.athlete_id / flutter.access_token).',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonitoringBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: Colors.green.shade100,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Live monitoring active - new sleep data will appear automatically',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateRangeSelector() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final range in [
              'Last 24 hours',
              'Last 3 days',
              'Last 7 days',
              'Custom',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: ChoiceChip(
                  label: Text(
                    range == 'Custom' && _customStartDate != null
                        ? '${_customStartDate!.month}/${_customStartDate!.day} - ${_customEndDate!.month}/${_customEndDate!.day}'
                        : range,
                  ),
                  selected: _selectedRange == range,
                  onSelected: (selected) {
                    if (selected) {
                      if (range == 'Custom') {
                        _selectCustomDateRange();
                      } else {
                        setState(() => _selectedRange = range);
                        _fetchSleepData();
                      }
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Error fetching sleep data',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _fetchSleepData,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_sleepData == null || !_sleepData!.hasSleepData) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bedtime_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No sleep data found'),
            const SizedBox(height: 8),
            const Text(
              'Sleep data from the last 24 hours will appear here',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchSleepData,
              child: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchSleepData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSummaryCard(),
            const SizedBox(height: 16),
            _buildStageBreakdownCard(),
            const SizedBox(height: 16),
            _buildSamplesSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard() {
    final data = _sleepData!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bedtime, color: Colors.indigo),
                const SizedBox(width: 8),
                Text(
                  'Sleep Summary',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(),
            _buildStatRow(
              'Total Sleep',
              _fmtMinutes(data.totalSleepMinutes),
              Icons.access_time,
            ),
            _buildStatRow('Samples', '${data.sampleCount}', Icons.list),
            _buildStatRow(
              'Time Range',
              '${_formatTime(data.fetchedFrom)} - ${_formatTime(data.fetchedTo)}',
              Icons.date_range,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStageBreakdownCard() {
    final totals = _sleepData!.stageTotals;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bar_chart, color: Colors.purple),
                const SizedBox(width: 8),
                Text(
                  'Sleep Stages',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const Divider(),
            _buildStageRow(
              'Deep Sleep',
              totals.asleepDeepMinutes,
              Colors.indigo,
            ),
            _buildStageRow('REM Sleep', totals.asleepREMMinutes, Colors.purple),
            _buildStageRow('Core Sleep', totals.asleepCoreMinutes, Colors.blue),
            _buildStageRow('Awake', totals.awakeMinutes, Colors.orange),
            _buildStageRow('In Bed', totals.inBedMinutes, Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildStageRow(String label, double minutes, Color color) {
    final totalMinutes =
        _sleepData!.stageTotals.totalSleepMinutes +
        _sleepData!.stageTotals.awakeMinutes +
        _sleepData!.stageTotals.inBedMinutes;
    final percentage = totalMinutes > 0 ? (minutes / totalMinutes) * 100 : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
          Text('${_fmtMinutes(minutes)} (${percentage.toStringAsFixed(0)}%)'),
        ],
      ),
    );
  }

  Widget _buildSamplesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.list_alt, color: Colors.teal),
            const SizedBox(width: 8),
            Text(
              'Individual Samples',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._sleepData!.samples.map((sample) => _buildSampleCard(sample)),
      ],
    );
  }

  Widget _buildSampleCard(SleepSample sample) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: Icon(
          _getStageIcon(sample.sleepStage),
          color: _getStageColor(sample.sleepStage),
        ),
        title: Text(
          _formatStageName(sample.sleepStage),
          style: TextStyle(
            color: _getStageColor(sample.sleepStage),
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          '${_fmtMinutes(sample.durationMinutes)} • ${sample.sourceName ?? 'Unknown source'}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetailRow('Start', _formatDateTime(sample.startDate)),
                _buildDetailRow('End', _formatDateTime(sample.endDate)),
                _buildDetailRow(
                  'Duration',
                  _fmtMinutes(sample.durationMinutes),
                ),
                _buildDetailRow('Source', sample.sourceName ?? 'Unknown'),
                _buildDetailRow('Bundle', sample.sourceBundle ?? 'Unknown'),
                if (sample.device != null) ...[
                  _buildDetailRow('Device', sample.device!.name ?? 'Unknown'),
                  _buildDetailRow('Model', sample.device!.model ?? 'Unknown'),
                ],
                const Divider(),
                ExpansionTile(
                  title: const Text('Raw JSON'),
                  tilePadding: EdgeInsets.zero,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        _formatJson(sample.rawJson),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Text(label),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(color: Colors.grey[600])),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Color _getStageColor(String stage) {
    switch (stage) {
      case 'asleepDeep':
        return Colors.indigo;
      case 'asleepREM':
        return Colors.purple;
      case 'asleepCore':
        return Colors.blue;
      case 'awake':
        return Colors.orange;
      case 'inBed':
        return Colors.grey;
      default:
        return Colors.teal;
    }
  }

  IconData _getStageIcon(String stage) {
    switch (stage) {
      case 'asleepDeep':
        return Icons.nights_stay;
      case 'asleepREM':
        return Icons.auto_awesome;
      case 'asleepCore':
        return Icons.bedtime;
      case 'awake':
        return Icons.wb_sunny;
      case 'inBed':
        return Icons.bed;
      default:
        return Icons.help_outline;
    }
  }

  String _formatStageName(String stage) {
    switch (stage) {
      case 'asleepDeep':
        return 'Deep Sleep';
      case 'asleepREM':
        return 'REM Sleep';
      case 'asleepCore':
        return 'Core Sleep';
      case 'asleepUnspecified':
        return 'Asleep';
      case 'awake':
        return 'Awake';
      case 'inBed':
        return 'In Bed';
      default:
        return stage;
    }
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${_formatTime(dt)}';
  }

  String _formatJson(Map<String, dynamic> json) {
    // Simple JSON formatting
    final buffer = StringBuffer();
    _formatJsonValue(json, buffer, 0);
    return buffer.toString();
  }

  void _formatJsonValue(dynamic value, StringBuffer buffer, int indent) {
    final indentStr = '  ' * indent;
    if (value is Map) {
      buffer.writeln('{');
      final entries = value.entries.toList();
      for (int i = 0; i < entries.length; i++) {
        buffer.write('$indentStr  "${entries[i].key}": ');
        _formatJsonValue(entries[i].value, buffer, indent + 1);
        if (i < entries.length - 1) buffer.write(',');
        buffer.writeln();
      }
      buffer.write('$indentStr}');
    } else if (value is List) {
      buffer.writeln('[');
      for (int i = 0; i < value.length; i++) {
        buffer.write('$indentStr  ');
        _formatJsonValue(value[i], buffer, indent + 1);
        if (i < value.length - 1) buffer.write(',');
        buffer.writeln();
      }
      buffer.write('$indentStr]');
    } else if (value is String) {
      buffer.write('"$value"');
    } else {
      buffer.write('$value');
    }
  }

  /// Formats a duration given in minutes as "Xh Ym" (e.g. 387 min → "6h 27m").
  /// Falls back to "Ym" when under 1 hour, and "Xs" when under 1 minute.
  String _fmtMinutes(double minutes) {
    if (minutes <= 0) return '0m';
    final totalSeconds = (minutes * 60).round();
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    if (m > 0) return '${m}m';
    return '${s}s';
  }

  // ── Background Payloads Card ───────────────────────────────────────────────
  // Populated on AppLifecycleState.resumed by draining getLocalSleepSessions().
  // Runner’s HealthQueueObserver already posted a local notification while the
  // app was suspended — this card is the in-app view of those payloads.

  Widget _buildBackgroundPayloadsCard() {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      color: Colors.indigo.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notifications_active, color: Colors.indigo),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Background Payloads ($_bgPayloadCount received)',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.indigo,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _backgroundPayloads.clear();
                    _bgPayloadCount = 0;
                  }),
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Stored by iOS background pipeline — drained on app resume. '
              "Runner's HealthQueueObserver sent the local notification.",
              style: TextStyle(fontSize: 11, color: Colors.indigo.shade700),
            ),
            const Divider(),
            // Show last 3 payloads
            ..._backgroundPayloads.take(3).map((payload) {
              final source =
                  payload['SOURCE'] as String? ??
                  (payload['raw'] as String? ?? 'unknown');
              final totalSec = payload['TOTAL_SLEEP'] as int?;
              final bedTime = payload['BED_TIME'] as String? ?? '';
              final wakeTime = payload['WAKE_TIME'] as String? ?? '';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    const Icon(Icons.bedtime, size: 14, color: Colors.indigo),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        totalSec != null
                            ? '${_fmtMinutes(totalSec / 60)} · $source'
                            : source,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (bedTime.isNotEmpty && wakeTime.isNotEmpty)
                      Text(
                        '${bedTime.length > 10 ? bedTime.substring(11, 16) : bedTime}'
                        ' → ${wakeTime.length > 10 ? wakeTime.substring(11, 16) : wakeTime}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.indigo.shade400,
                        ),
                      ),
                  ],
                ),
              );
            }),
            if (_backgroundPayloads.length > 3)
              Text(
                '+ ${_backgroundPayloads.length - 3} more',
                style: TextStyle(fontSize: 11, color: Colors.indigo.shade400),
              ),
          ],
        ),
      ),
    );
  }

  // ── Calculate Payload Section ─────────────────────────────────────────────

  Widget _buildCalculatePayloadSection() {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      color: Colors.teal.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calculate, color: Colors.teal, size: 18),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '🧮 Group-Based Sleep Payload',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                if (_isCalcLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Run'),
                    onPressed: _runCalculateSleepPayload,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.teal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                    ),
                  ),
              ],
            ),
            Text(
              'Groups samples (gap ≤ 2h) → drops sessions < 3h → ceiling-rounds durations.',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
            if (_calcError != null) ...[
              const SizedBox(height: 6),
              Text(
                _calcError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
            if (_calcPayload != null) ...[
              const Divider(height: 12),
              ..._buildPayloadRows(_calcPayload!),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtSeconds(dynamic v) {
    if (v == null) return '-';
    final secs = (v is int) ? v : (v as num).toInt();
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) return '${h}h ${m}m';
    if (s == 0) return '${m}m';
    return '${m}m ${s}s';
  }

  List<Widget> _buildPayloadRows(Map<String, dynamic> payload) {
    return [
      _buildPayloadRow('Source', payload['SOURCE']?.toString() ?? '-'),
      _buildPayloadRow('Total Sleep', _fmtSeconds(payload['TOTAL_SLEEP'])),
      _buildPayloadRow('Light (Core)', _fmtSeconds(payload['SLEEP_LIGHT'])),
      _buildPayloadRow('Deep', _fmtSeconds(payload['SLEEP_DEEP'])),
      _buildPayloadRow('REM', _fmtSeconds(payload['SLEEP_REM'])),
      _buildPayloadRow('Awake', _fmtSeconds(payload['SLEEP_AWAKE'])),
      _buildPayloadRow('In Bed', _fmtSeconds(payload['SLEEP_IN_BED'])),
      _buildPayloadRow('Bed Time', payload['BED_TIME']?.toString() ?? '-'),
      _buildPayloadRow('Wake Time', payload['WAKE_TIME']?.toString() ?? '-'),
      _buildPayloadRow('Timezone', payload['TIMEZONE']?.toString() ?? '-'),
    ];
  }

  Widget _buildPayloadRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
