import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Wire up the queue observer. It will auto-start if the user is already
    // logged in (persisted UserDefaults), and will start/stop automatically
    // whenever Flutter calls setUserLoggedIn(true/false) via the session channel.
    HealthQueueObserver.shared.setup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    // Log what is currently in the queues so background delivery can be verified
    // in the Xcode console without needing a backend.
    HealthQueueObserver.shared.onEnterBackground()
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    // Retry any pending sleep uploads (in case background upload was skipped
    // due to missing credentials) before Flutter's lifecycle resumes.
    // Flutter's _drainBackgroundPayloads() will then read any sessions that
    // still remain in UserDefaults for display.
    HealthQueueObserver.shared.onEnterForeground()
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
