//
//  ExampleSessionChannel.swift
//  Runner (example app)
//
//  Flutter → Native method channel for session management in the example app.
//  Channel: "com.humango.example/session"
//
//  This replaces the library's built-in `setUserLoginState` channel call so
//  the example app can control login state and delegate injection natively,
//  exactly as a production host app would (e.g. humango_workouts).
//
//  Methods:
//    setLoggedIn   → injects ExampleHealthDataHandler delegate,
//                    starts all background monitoring
//    setLoggedOut  → calls HumangoHealthPlugin.shared?.logout()
//                    which stops all monitors and clears stored data
//

import Flutter
import UIKit
import humango_health

final class ExampleSessionChannel: NSObject, FlutterPlugin {

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.humango.example/session",
            binaryMessenger: registrar.messenger()
        )
        let instance = ExampleSessionChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - Method dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "setLoggedIn":
            UserDefaults.standard.set(true, forKey: "com.humango.example.isLoggedIn")
             print("[Example][Session] ✅ User logged in — flag saved, monitoring started")
            result(nil)

        case "setLoggedOut":
            UserDefaults.standard.set(false, forKey: "com.humango.example.isLoggedIn")
            HumangoHealthPlugin.shared?.logout()
            HumangoHealthPlugin.delegate = nil
            print("[Example][Session] 🔒 User logged out — flag cleared, monitoring stopped")
            result(nil)

        case "startBackgroundMonitoring":
            UserDefaults.standard.set(true, forKey: "com.humango.example.isLoggedIn")
            HumangoHealthPlugin.delegate = ExampleHealthDataHandler()
            HumangoHealthPlugin.shared?.startActivityBackgroundMonitoring()
            HumangoHealthPlugin.shared?.startSleepBackgroundMonitoring()
            HumangoHealthPlugin.shared?.startMetricsMonitoring(for: [.restingHeartRate, .bodyFatPercentage,.bodyMass])
            print("VINAY: [Example][Session] ▶️ startBackgroundMonitoring called — delegate set, monitoring started")
            result(nil)

        case "stopBackgroundMonitoring":
            UserDefaults.standard.set(false, forKey: "com.humango.example.isLoggedIn")
            // HumangoHealthPlugin.shared?.stopActivityBackgroundMonitoring()
            // HumangoHealthPlugin.shared?.stopSleepBackgroundMonitoring()
            HumangoHealthPlugin.shared?.stopAllMetricsMonitoring()
            print("VINAY: [Example][Session] ⏹️ stopBackgroundMonitoring called")
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
