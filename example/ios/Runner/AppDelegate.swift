import Flutter
import UIKit
import humango_health

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Pre-set the delegate BEFORE plugin registration so that on a background relaunch
    // (app was killed; HealthKit wakes it for sleep/workout delivery) the delegate is
    // already in place when HumangoHealthPlugin.register() calls startAllBackgroundMonitoring().
    // In the normal foreground flow ExampleSessionChannel.setLoggedIn() overwrites this with
    // the same handler type — no functional difference.
    HumangoHealthPlugin.delegate = ExampleHealthDataHandler()

    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register the example-app session channel so Flutter can set login state
    // and trigger background monitoring natively (no library setUserLoginState).
    ExampleSessionChannel.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "ExampleSessionChannel")!
    )
  }
}
