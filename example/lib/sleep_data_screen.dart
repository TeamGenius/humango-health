import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:humango_health/humango_health.dart';
import 'sleep_data_provider.dart';

class SleepDataScreen extends StatelessWidget {
  const SleepDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sleep Analytics')),
      body: Consumer<SleepDataProvider>(
        builder: (context, provider, child) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () => provider.fetchCurrentRecord(),
                      child: const Text("Get Today's Score"),
                    ),
                    ElevatedButton(
                      onPressed: () => provider.fetchSleepHistory(),
                      child: const Text("Fetch Past 7 Days"),
                    ),
                    ElevatedButton(
                      onPressed: () => provider.clearData(),
                      child: const Text("Clear"),
                    ),
                  ],
                ),
              ),
              if (provider.isLoading)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(),
                ),
              const Divider(),
              if (provider.currentRecord != null) ...[
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text("Latest Nightly Record", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                _buildSleepCard(context, provider.currentRecord!),
                const Divider(),
              ],
              Expanded(
                child: provider.sleepHistory.isEmpty
                    ? const Center(child: Text('No history fetched yet.'))
                    : ListView.builder(
                        itemCount: provider.sleepHistory.length,
                        itemBuilder: (context, index) {
                          return _buildSleepCard(context, provider.sleepHistory[index]);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSleepCard(BuildContext context, SleepData session) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
      child: InkWell(
        onTap: () {
          _showDetailSheet(context, session);
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    session.date.toString().split(' ')[0],
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: session.sleepScore >= 80 ? Colors.green : (session.sleepScore >= 60 ? Colors.orange : Colors.red),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      "${session.sleepScore.toStringAsFixed(1)} Score",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  )
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildMetric("In Bed", _formatDuration(session.totalInBed)),
                  _buildMetric("Asleep", _formatDuration(session.totalAsleep)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                "${session.stages.length} distinct stages recorded",
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildMetric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.blueAccent)),
      ],
    );
  }

  String _formatDuration(Duration d) {
    int hours = d.inHours;
    int minutes = d.inMinutes.remainder(60);
    return "${hours}h ${minutes}m";
  }

  void _showDetailSheet(BuildContext context, SleepData session) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) {
            return Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.deepPurpleAccent.withValues(alpha: 0.1),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Center(
                    child: Text(
                      "Sleep Stages - ${session.date.toString().split(' ')[0]}",
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    itemCount: session.stages.length,
                    separatorBuilder: (context, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final stage = session.stages[index];
                      // Simple mapping for colors
                      Color iconColor = Colors.grey;
                      switch (stage.stage) {
                        case 'inBed': iconColor = Colors.grey; break;
                        case 'awake': iconColor = Colors.orange; break;
                        case 'asleepCore': iconColor = Colors.lightBlue; break;
                        case 'asleepDeep': iconColor = Colors.indigo; break;
                        case 'asleepREM': iconColor = Colors.purple; break;
                      }
                      
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: iconColor.withValues(alpha: 0.2),
                          child: Icon(Icons.bedtime, color: iconColor),
                        ),
                        title: Text(
                          stage.stage.toUpperCase(),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          "From: ${stage.startDate.toString().split('.')[0]}\n"
                          "To:   ${stage.endDate.toString().split('.')[0]}",
                        ),
                        trailing: Text(
                          _formatDuration(stage.endDate.difference(stage.startDate)),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black54),
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
