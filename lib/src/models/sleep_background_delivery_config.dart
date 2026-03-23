/// Sleep session delivery: finalized sessions are stored in UserDefaults for retrieval
/// via [SleepDataManager] APIs. The plugin does not POST sleep payloads to your API.
enum SleepBackgroundDeliveryMode {
  localStorage,
}

class SleepBackgroundDeliveryConfig {
  final SleepBackgroundDeliveryMode mode;

  const SleepBackgroundDeliveryConfig({
    this.mode = SleepBackgroundDeliveryMode.localStorage,
  });

  Map<String, dynamic> toJson() {
    return {'mode': mode.name};
  }

  factory SleepBackgroundDeliveryConfig.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    final mode = SleepBackgroundDeliveryMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => SleepBackgroundDeliveryMode.localStorage,
    );
    return SleepBackgroundDeliveryConfig(mode: mode);
  }
}
