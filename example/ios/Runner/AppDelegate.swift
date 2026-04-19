import Flutter
import UIKit
import humango_health

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register HKObserverQueries synchronously before returning.
    // Apple requires observers to be set up here so HealthKit can fire them
    // immediately on a background launch, before the Flutter engine initialises.
    // HumangoHealthPlugin.shared is nil at this point — we call the singletons directly.
    let isLoggedIn = UserDefaults.standard.bool(forKey: "com.humango.example.isLoggedIn")
    if isLoggedIn {
      HumangoHealthPlugin.delegate = ExampleHealthDataHandler()
       SleepDataManager.shared.startMonitoring()
       WorkoutServiceChannel.shared.startMonitoring()
      HealthMetricsManager.shared.startMonitoring(.restingHeartRate)
      HealthMetricsManager.shared.startMonitoring(.bodyFatPercentage)
       HealthMetricsManager.shared.startMonitoring(.bodyMass)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Example app: always set the delegate and start monitoring on every app open.
    HumangoHealthPlugin.delegate = ExampleHealthDataHandler()
    print("[Example][AppDelegate] ✅ Delegate set + monitoring started")

    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register the example-app session channel so Flutter can set login state
    // and trigger background monitoring natively.
    ExampleSessionChannel.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "ExampleSessionChannel")!
    )
  }
}
