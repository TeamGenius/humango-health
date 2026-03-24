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
//    setLoggedIn   → UserAuthStateManager.isLoggedIn = true,
//                    injects ExampleHealthDataHandler delegate,
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
            UserAuthStateManager.shared.isLoggedIn = true
            HumangoHealthPlugin.delegate = ExampleHealthDataHandler()
            HumangoHealthPlugin.shared?.startAllBackgroundMonitoring()
            print("[Example][Session] ✅ User logged in — monitoring started")
            result(nil)

        case "setLoggedOut":
            HumangoHealthPlugin.shared?.logout()
            print("[Example][Session] 🔒 User logged out — monitoring stopped")
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
