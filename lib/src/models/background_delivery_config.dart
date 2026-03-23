/// Workout background delivery: [workoutStream] when the app has a listener, otherwise
/// native queues JSON in UserDefaults until the host app reads it (no HTTP from the plugin).
enum BackgroundDeliveryMode {
  localStorage,
}

class BackgroundDeliveryConfig {
  final BackgroundDeliveryMode mode;

  const BackgroundDeliveryConfig({
    this.mode = BackgroundDeliveryMode.localStorage,
  });

  Map<String, dynamic> toJson() {
    return {'mode': mode.name};
  }

  factory BackgroundDeliveryConfig.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    final mode = BackgroundDeliveryMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => BackgroundDeliveryMode.localStorage,
    );
    return BackgroundDeliveryConfig(mode: mode);
  }
}
