//
//  HealthMetricsManager.swift
//  humango_health
//
//  Generic HKQuantityType reader for body metrics and vital signs.
//  Supports: HRV, resting heart rate, body fat %, weight (bodyMass), height
//

import Flutter
import HealthKit
import Foundation

// MARK: - Supported Metric Types

/// Maps Flutter metric key → (HKQuantityTypeIdentifier, preferred HKUnit, unit label)
private struct MetricDescriptor {
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let unitLabel: String
}

private let metricDescriptors: [String: MetricDescriptor] = [
    "heartRateVariabilitySDNN": MetricDescriptor(
        identifier: .heartRateVariabilitySDNN,
        unit: HKUnit.secondUnit(with: .milli),
        unitLabel: "ms"
    ),
    "restingHeartRate": MetricDescriptor(
        identifier: .restingHeartRate,
        unit: HKUnit.count().unitDivided(by: .minute()),
        unitLabel: "bpm"
    ),
    "bodyFatPercentage": MetricDescriptor(
        identifier: .bodyFatPercentage,
        unit: HKUnit.percent(),
        unitLabel: "%"
    ),
    "bodyMass": MetricDescriptor(
        identifier: .bodyMass,
        unit: HKUnit.gramUnit(with: .kilo),
        unitLabel: "kg"
    ),
    "height": MetricDescriptor(
        identifier: .height,
        unit: HKUnit.meterUnit(with: .centi),
        unitLabel: "cm"
    ),
]

// MARK: - HealthMetricsManager

public class HealthMetricsManager: NSObject {
    static let shared = HealthMetricsManager()
    
    private var healthStore: HKHealthStore { SharedHealthKitStore.shared }
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    // MARK: - Method Channel Handler
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getHealthMetric":
            handleGetHealthMetric(call, result: result)
        case "getLatestHealthMetric":
            handleGetLatestHealthMetric(call, result: result)
        case "getAllHealthMetrics":
            handleGetAllHealthMetrics(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Method Handlers
    
    /// Fetch samples for a single metric type within a date range
    private func handleGetHealthMetric(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let metricType = args["metricType"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "metricType is required", details: nil))
            return
        }
        
        guard let descriptor = metricDescriptors[metricType] else {
            result(FlutterError(code: "UNKNOWN_METRIC", message: "Unknown metric type: \(metricType). Supported: \(Array(metricDescriptors.keys))", details: nil))
            return
        }
        
        let startDate = parseDate(args["startDate"] as? String) ?? Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let endDate = parseDate(args["endDate"] as? String) ?? Date()
        let limit = args["limit"] as? Int ?? HKObjectQueryNoLimit
        
        Task {
            do {
                let response = try await fetchSamples(
                    identifier: descriptor.identifier,
                    unit: descriptor.unit,
                    unitLabel: descriptor.unitLabel,
                    metricType: metricType,
                    startDate: startDate,
                    endDate: endDate,
                    limit: limit,
                    ascending: true
                )
                DispatchQueue.main.async { result(response) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FETCH_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    /// Fetch only the latest (most recent) sample for a single metric type
    private func handleGetLatestHealthMetric(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let metricType = args["metricType"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "metricType is required", details: nil))
            return
        }
        
        guard let descriptor = metricDescriptors[metricType] else {
            result(FlutterError(code: "UNKNOWN_METRIC", message: "Unknown metric type: \(metricType)", details: nil))
            return
        }
        
        Task {
            do {
                let response = try await fetchSamples(
                    identifier: descriptor.identifier,
                    unit: descriptor.unit,
                    unitLabel: descriptor.unitLabel,
                    metricType: metricType,
                    startDate: Date.distantPast,
                    endDate: Date(),
                    limit: 1,
                    ascending: false
                )
                DispatchQueue.main.async { result(response) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "FETCH_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    /// Fetch latest sample for ALL supported metric types in one call
    private func handleGetAllHealthMetrics(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        var startDate: Date?
        var endDate: Date?
        
        if let args = call.arguments as? [String: Any] {
            startDate = parseDate(args["startDate"] as? String)
            endDate = parseDate(args["endDate"] as? String)
        }
        
        let queryEndDate = endDate ?? Date()
        let queryStartDate = startDate ?? Calendar.current.date(byAdding: .day, value: -30, to: queryEndDate)!
        
        Task {
            var allMetrics: [String: Any] = [:]
            var errors: [String: String] = [:]
            
            for (key, descriptor) in metricDescriptors {
                do {
                    let response = try await fetchSamples(
                        identifier: descriptor.identifier,
                        unit: descriptor.unit,
                        unitLabel: descriptor.unitLabel,
                        metricType: key,
                        startDate: queryStartDate,
                        endDate: queryEndDate,
                        limit: HKObjectQueryNoLimit,
                        ascending: true
                    )
                    allMetrics[key] = response
                } catch {
                    errors[key] = error.localizedDescription
                    print("📊 [Humango Health] Error fetching \(key): \(error.localizedDescription)")
                }
            }
            
            let combinedResult: [String: Any] = [
                "metrics": allMetrics,
                "errors": errors,
                "fetchedFrom": isoFormatter.string(from: queryStartDate),
                "fetchedTo": isoFormatter.string(from: queryEndDate),
            ]
            
            DispatchQueue.main.async { result(combinedResult) }
        }
    }
    
    // MARK: - Core HealthKit Query
    
    private func fetchSamples(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        unitLabel: String,
        metricType: String,
        startDate: Date,
        endDate: Date,
        limit: Int,
        ascending: Bool
    ) async throws -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthMetrics", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HealthKit is not available on this device"
            ])
        }
        
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw NSError(domain: "HealthMetrics", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Quantity type not available: \(identifier.rawValue)"
            ])
        }
        
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: ascending
        )
        
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Error>) in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let quantitySamples = results as? [HKQuantitySample] ?? []
                continuation.resume(returning: quantitySamples)
            }
            healthStore.execute(query)
        }
        
        // Convert samples to dictionaries
        var sampleDicts: [[String: Any]] = []
        var latestSample: [String: Any]? = nil
        var sum: Double = 0
        var min: Double = Double.greatestFiniteMagnitude
        var max: Double = -Double.greatestFiniteMagnitude
        
        for sample in samples {
            let value = sample.quantity.doubleValue(for: unit)
            let dict = convertQuantitySampleToDict(sample, value: value, unit: unit, unitLabel: unitLabel)
            sampleDicts.append(dict)
            
            sum += value
            if value < min { min = value }
            if value > max { max = value }
        }
        
        // Latest is last if ascending, first if descending
        if !sampleDicts.isEmpty {
            latestSample = ascending ? sampleDicts.last : sampleDicts.first
        }
        
        let count = samples.count
        let average = count > 0 ? sum / Double(count) : 0
        
        // Reset min/max if empty
        if count == 0 { min = 0; max = 0 }
        
        print("📊 [Humango Health] Fetched \(count) \(metricType) samples")
        
        return [
            "metricType": metricType,
            "unit": unitLabel,
            "samples": sampleDicts,
            "sampleCount": count,
            "latestSample": latestSample as Any,
            "statistics": [
                "average": average,
                "min": min,
                "max": max,
                "sum": sum,
            ],
            "fetchedFrom": isoFormatter.string(from: startDate),
            "fetchedTo": isoFormatter.string(from: endDate),
        ]
    }
    
    // MARK: - Convert Sample to Dictionary
    
    private func convertQuantitySampleToDict(
        _ sample: HKQuantitySample,
        value: Double,
        unit: HKUnit,
        unitLabel: String
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "uuid": sample.uuid.uuidString,
            "value": value,
            "unit": unitLabel,
            "startDate": isoFormatter.string(from: sample.startDate),
            "endDate": isoFormatter.string(from: sample.endDate),
            "sourceName": sample.sourceRevision.source.name,
            "sourceBundle": sample.sourceRevision.source.bundleIdentifier,
        ]
        
        if let device = sample.device {
            var deviceDict: [String: Any] = [:]
            if let name = device.name { deviceDict["name"] = name }
            if let model = device.model { deviceDict["model"] = model }
            if let manufacturer = device.manufacturer { deviceDict["manufacturer"] = manufacturer }
            if let hardwareVersion = device.hardwareVersion { deviceDict["hardwareVersion"] = hardwareVersion }
            if let softwareVersion = device.softwareVersion { deviceDict["softwareVersion"] = softwareVersion }
            if let localIdentifier = device.localIdentifier { deviceDict["localIdentifier"] = localIdentifier }
            dict["device"] = deviceDict
        }
        
        if let metadata = sample.metadata, !metadata.isEmpty {
            var metadataDict: [String: Any] = [:]
            for (key, metaValue) in metadata {
                if let stringValue = metaValue as? String {
                    metadataDict[key] = stringValue
                } else if let numberValue = metaValue as? NSNumber {
                    metadataDict[key] = numberValue
                } else if let dateValue = metaValue as? Date {
                    metadataDict[key] = isoFormatter.string(from: dateValue)
                } else {
                    metadataDict[key] = String(describing: metaValue)
                }
            }
            dict["metadata"] = metadataDict
        }
        
        // Include raw JSON representation
        dict["rawJson"] = dict
        
        return dict
    }
    
    // MARK: - Helpers
    
    private func parseDate(_ dateString: String?) -> Date? {
        guard let str = dateString else { return nil }
        return ISO8601DateFormatter().date(from: str) ?? isoFormatter.date(from: str)
    }
}
