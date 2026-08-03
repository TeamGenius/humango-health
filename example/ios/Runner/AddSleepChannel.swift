import Flutter
import Foundation
import HealthKit

final class AddSleepChannel: NSObject, FlutterPlugin {

    private let healthStore = HKHealthStore()

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.humango.example/addSleep",
            binaryMessenger: registrar.messenger()
        )
        let instance = AddSleepChannel()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "addSleepSample":
            guard
                let args = call.arguments as? [String: Any],
                let startISO = args["startDate"] as? String,
                let endISO = args["endDate"] as? String,
                let stageRaw = args["sleepStage"] as? String
            else {
                result(FlutterError(
                    code: "INVALID_ARGS",
                    message: "startDate, endDate, and sleepStage are required",
                    details: nil
                ))
                return
            }

            guard let startDate = Self.parseISODate(startISO), let endDate = Self.parseISODate(endISO) else {
                result(FlutterError(
                    code: "INVALID_DATE",
                    message: "Dates must be valid ISO8601 strings",
                    details: nil
                ))
                return
            }

            guard endDate > startDate else {
                result(FlutterError(
                    code: "INVALID_RANGE",
                    message: "endDate must be after startDate",
                    details: nil
                ))
                return
            }

            guard let stage = mapSleepStage(stageRaw) else {
                result(FlutterError(
                    code: "INVALID_STAGE",
                    message: "Unsupported sleep stage: \(stageRaw)",
                    details: nil
                ))
                return
            }

            addSleepSample(
                startDate: startDate,
                endDate: endDate,
                stageRaw: stageRaw,
                stage: stage,
                result: result
            )

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func addSleepSample(
        startDate: Date,
        endDate: Date,
        stageRaw: String,
        stage: HKCategoryValueSleepAnalysis,
        result: @escaping FlutterResult
    ) {
        guard HKHealthStore.isHealthDataAvailable() else {
            result(FlutterError(
                code: "HK_UNAVAILABLE",
                message: "HealthKit is not available on this device",
                details: nil
            ))
            return
        }

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            result(FlutterError(
                code: "TYPE_UNAVAILABLE",
                message: "Sleep Analysis type is unavailable",
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
                        message: "HealthKit authorization was denied",
                        details: nil
                    ))
                }
                return
            }

            let sample = HKCategorySample(
                type: sleepType,
                value: stage.rawValue,
                start: startDate,
                end: endDate
            )

            self.healthStore.save(sample) { saved, saveError in
                DispatchQueue.main.async {
                    if let saveError = saveError {
                        result(FlutterError(
                            code: "SAVE_FAILED",
                            message: saveError.localizedDescription,
                            details: nil
                        ))
                        return
                    }

                    guard saved else {
                        result(FlutterError(
                            code: "SAVE_FAILED",
                            message: "HealthKit did not confirm sample save",
                            details: nil
                        ))
                        return
                    }

                    let payload: [String: Any] = [
                        "saved": true,
                        "uuid": sample.uuid.uuidString,
                        "sleepStage": stageRaw,
                        "startDate": Self.makeISOFormatter().string(from: startDate),
                        "endDate": Self.makeISOFormatter().string(from: endDate),
                    ]
                    result(payload)
                }
            }
        }
    }

    private func mapSleepStage(_ raw: String) -> HKCategoryValueSleepAnalysis? {
        switch raw {
        case "asleepUnspecified":
            return .asleepUnspecified
        case "asleepCore":
            if #available(iOS 16.0, *) {
                return .asleepCore
            }
            return nil
        case "asleepDeep":
            if #available(iOS 16.0, *) {
                return .asleepDeep
            }
            return nil
        case "asleepREM":
            if #available(iOS 16.0, *) {
                return .asleepREM
            }
            return nil
        default:
            return nil
        }
    }

    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatterWithFractional = makeISOFormatter()
        if let date = formatterWithFractional.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
