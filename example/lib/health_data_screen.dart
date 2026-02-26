import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:humango_health/humango_health.dart';
import 'health_data_provider.dart';

class HealthDataScreen extends StatelessWidget {
  const HealthDataScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Health Data Explorer')),
      body: Consumer<HealthDataProvider>(
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
                      onPressed: () => provider.fetchHistoricalData(),
                      child: const Text("Fetch Past 7 Days (Steps)"),
                    ),
                    ElevatedButton(
                      onPressed: () => provider.fetchBackgroundData(),
                      child: const Text("Load Stored Background Data"),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: provider.isMonitoring ? Colors.red : Colors.green,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => provider.toggleMonitoring(),
                      child: Text(provider.isMonitoring ? "Stop Live Stream" : "Start Live Stream"),
                    ),
                    ElevatedButton(
                      onPressed: () => provider.clearData(),
                      child: const Text("Clear Results"),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Expanded(
                child: provider.data.isEmpty
                    ? const Center(child: Text('No data fetched yet.'))
                    : ListView.builder(
                        itemCount: provider.data.length,
                        itemBuilder: (context, index) {
                          final type = provider.data.keys.elementAt(index);
                          final samples = provider.data[type]!;
                          
                          if (samples.isEmpty) return const SizedBox.shrink();
                          
                          final latestSample = samples.first;
                          String displayValue = _formatValue(latestSample.value);

                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            elevation: 4,
                            child: InkWell(
                              onTap: () {
                                _showDetailSheet(context, type, samples);
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
                                          type.name.toUpperCase(),
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    const Text(
                                      "Latest Value",
                                      style: TextStyle(color: Colors.grey, fontSize: 12),
                                    ),
                                    Text(
                                      displayValue,
                                      style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.blueAccent,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      "Last updated: ${latestSample.endDate.toString().split('.')[0]}",
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                    Text(
                                      "History count: ${samples.length} items",
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showDetailSheet(BuildContext context, HealthDataType type, List<HealthDataSample> samples) {
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
                    color: Colors.blueAccent.withValues(alpha: 0.1),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  child: Center(
                    child: Text(
                      "${type.name} - History",
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    controller: scrollController,
                    itemCount: samples.length,
                    separatorBuilder: (context, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final sample = samples[index];
                      return ListTile(
                        title: Text(
                          _formatValue(sample.value),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          "From: ${sample.startDate.toString().split('.')[0]}\n"
                          "To:   ${sample.endDate.toString().split('.')[0]}",
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

  String _formatValue(HealthDataValue value) {
    if (value.isQuantity) {
      return "${value.numericValue?.toStringAsFixed(2)} ${value.unit}";
    } else if (value.isCategory) {
      return "Category: ${value.categoryValue}";
    }
    return "Unknown Content";
  }
}
