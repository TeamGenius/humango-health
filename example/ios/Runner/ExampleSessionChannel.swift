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
import HealthKit
import humango_health

final class ExampleSessionChannel: NSObject, FlutterPlugin {

    private let healthStore = HKHealthStore()

    // MARK: - Registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let sessionChannel = FlutterMethodChannel(
            name: "com.humango.example/session",
            binaryMessenger: registrar.messenger()
        )
        let addSleepChannel = FlutterMethodChannel(
            name: "com.humango.example/addSleep",
            binaryMessenger: registrar.messenger()
        )
        let instance = ExampleSessionChannel()
        registrar.addMethodCallDelegate(instance, channel: sessionChannel)
        registrar.addMethodCallDelegate(instance, channel: addSleepChannel)
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

        case "addSleepSample":
            addSleepSample(call: call, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func addSleepSample(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let args = call.arguments as? [String: Any],
            let startISO = args["startDate"] as? String,
            let endISO = args["endDate"] as? String,
            let startDate = Self.parseISO(startISO),
            let endDate = Self.parseISO(endISO)
        else {
            result(FlutterError(
                code: "INVALID_ARGS",
                message: "startDate and endDate (ISO8601) are required",
                details: nil
            ))
            return
        }

        guard endDate > startDate else {
            result(FlutterError(
                code: "INVALID_RANGE",
                message: "endDate must be greater than startDate",
                details: nil
            ))
            return
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            result(FlutterError(
                code: "HEALTH_DATA_UNAVAILABLE",
                message: "Health data is not available on this device",
                details: nil
            ))
            return
        }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            result(FlutterError(
                code: "TYPE_UNAVAILABLE",
                message: "Could not resolve HealthKit sleep type",
                details: nil
            ))
            return
        }

        healthStore.requestAuthorization(toShare: [sleepType], read: [sleepType]) { [weak self] success, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "AUTH_ERROR",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
                return
            }

            guard success else {
                DispatchQueue.main.async {
                    result(FlutterError(
                        code: "AUTH_DENIED",
                        message: "HealthKit permission was not granted",
                        details: nil
                    ))
                }
                return
            }

            let sample = HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                start: startDate,
                end: endDate
            )

            self.healthStore.save(sample) { saved, saveError in
                DispatchQueue.main.async {
                    if let saveError = saveError {
                        result(FlutterError(
                            code: "SAVE_ERROR",
                            message: saveError.localizedDescription,
                            details: nil
                        ))
                        return
                    }

                    guard saved else {
                        result(FlutterError(
                            code: "SAVE_FAILED",
                            message: "Sleep sample save returned false",
                            details: nil
                        ))
                        return
                    }

                    result([
                        "sampleUuid": sample.uuid.uuidString,
                        "startDate": Self.makeISO().string(from: startDate),
                        "endDate": Self.makeISO().string(from: endDate)
                    ])
                }
            }
        }
    }

    private static func parseISO(_ value: String) -> Date? {
        let formatter = makeISO()
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func makeISO() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
