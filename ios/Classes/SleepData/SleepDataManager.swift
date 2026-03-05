//
//  SleepDataManager.swift
//  humango_health
//
//  Fetches sleep data from Apple HealthKit
//

import Flutter
import HealthKit
import Foundation

// MARK: - SleepDataManager

@available(iOS 14.0, *)
public class SleepDataManager: NSObject {
    static let shared = SleepDataManager()
    
    private let healthStore = HKHealthStore()
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    // MARK: - Method Channel Handler
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getSleepData":
            // Parse date parameters from arguments
            var startDate: Date?
            var endDate: Date?
            
            if let args = call.arguments as? [String: Any] {
                if let startStr = args["startDate"] as? String {
                    startDate = ISO8601DateFormatter().date(from: startStr) ?? isoFormatter.date(from: startStr)
                }
                if let endStr = args["endDate"] as? String {
                    endDate = ISO8601DateFormatter().date(from: endStr) ?? isoFormatter.date(from: endStr)
                }
            }
            
            Task {
                do {
                    let sleepData = try await fetchSleepData(startDate: startDate, endDate: endDate)
                    DispatchQueue.main.async {
                        result(sleepData)
                    }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(
                            code: "SLEEP_FETCH_ERROR",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    }
                }
            }
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Fetch Sleep Data
    
    /// Fetches sleep data for the specified time range
    /// - Parameters:
    ///   - startDate: Start of the time range (defaults to 24 hours ago)
    ///   - endDate: End of the time range (defaults to now)
    private func fetchSleepData(startDate: Date? = nil, endDate: Date? = nil) async throws -> [String: Any] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "SleepData", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HealthKit is not available on this device"
            ])
        }
        
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw NSError(domain: "SleepData", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Sleep analysis type is not available"
            ])
        }
        
        // Note: We cannot check read authorization status - Apple's privacy model
        // returns .notDetermined even if user granted/denied read access.
        // We simply query the data and return empty results if access is denied.
        
        // Define time range: use provided dates or default to last 24 hours
        let queryEndDate = endDate ?? Date()
        let queryStartDate = startDate ?? Calendar.current.date(byAdding: .hour, value: -24, to: queryEndDate)!
        
        let predicate = HKQuery.predicateForSamples(
            withStart: queryStartDate,
            end: queryEndDate,
            options: .strictStartDate
        )
        
        let sortDescriptor = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate,
            ascending: true
        )
        
        // Execute query
        let samples = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKCategorySample], Error>) in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                let categorySamples = results as? [HKCategorySample] ?? []
                continuation.resume(returning: categorySamples)
            }
            
            healthStore.execute(query)
        }
        
        // Convert samples to JSON
        var sleepSamples: [[String: Any]] = []
        var totalSleepSeconds: Double = 0
        var stageTotals: [String: Double] = [
            "inBed": 0,
            "asleepUnspecified": 0,
            "awake": 0,
            "asleepCore": 0,
            "asleepDeep": 0,
            "asleepREM": 0
        ]
        
        for sample in samples {
            let sampleDict = convertSampleToDict(sample)
            sleepSamples.append(sampleDict)
            
            let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
            let stageName = sleepStageString(from: sample.value)
            
            // Accumulate totals (exclude "inBed" and "awake" from total sleep)
            stageTotals[stageName, default: 0] += durationSeconds
            
            if stageName != "inBed" && stageName != "awake" {
                totalSleepSeconds += durationSeconds
            }
        }
        
        print("🛏️ [Humango Health] Fetched \(samples.count) sleep samples from \(isoFormatter.string(from: queryStartDate)) to \(isoFormatter.string(from: queryEndDate))")
        
        return [
            "samples": sleepSamples,
            "sampleCount": samples.count,
            "totalSleepSeconds": totalSleepSeconds,
            "totalSleepMinutes": totalSleepSeconds / 60.0,
            "totalSleepHours": totalSleepSeconds / 3600.0,
            "stageTotals": stageTotals.mapValues { ["seconds": $0, "minutes": $0 / 60.0] },
            "fetchedFrom": isoFormatter.string(from: queryStartDate),
            "fetchedTo": isoFormatter.string(from: queryEndDate)
        ]
    }
    
    // MARK: - Convert Sample to Dictionary
    
    private func convertSampleToDict(_ sample: HKCategorySample) -> [String: Any] {
        let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
        let stageName = sleepStageString(from: sample.value)
        
        var dict: [String: Any] = [
            "uuid": sample.uuid.uuidString,
            "startDate": isoFormatter.string(from: sample.startDate),
            "endDate": isoFormatter.string(from: sample.endDate),
            "value": sample.value,
            "sleepStage": stageName,
            "durationSeconds": durationSeconds,
            "durationMinutes": durationSeconds / 60.0
        ]
        
        // Source information
        dict["sourceName"] = sample.sourceRevision.source.name
        dict["sourceBundle"] = sample.sourceRevision.source.bundleIdentifier
        
        // Device information (if available)
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
        
        // Metadata (if available)
        if let metadata = sample.metadata, !metadata.isEmpty {
            var metadataDict: [String: Any] = [:]
            for (key, value) in metadata {
                // Convert metadata values to JSON-safe types
                if let stringValue = value as? String {
                    metadataDict[key] = stringValue
                } else if let numberValue = value as? NSNumber {
                    metadataDict[key] = numberValue
                } else if let dateValue = value as? Date {
                    metadataDict[key] = isoFormatter.string(from: dateValue)
                } else {
                    metadataDict[key] = String(describing: value)
                }
            }
            dict["metadata"] = metadataDict
        }
        
        // Include raw JSON representation
        dict["rawJson"] = dict
        
        return dict
    }
    
    // MARK: - Sleep Stage Conversion
    
    private func sleepStageString(from value: Int) -> String {
        guard let sleepValue = HKCategoryValueSleepAnalysis(rawValue: value) else {
            return "unknown"
        }
        
        switch sleepValue {
        case .inBed:
            return "inBed"
        case .asleepUnspecified:
            return "asleepUnspecified"
        case .awake:
            return "awake"
        case .asleepCore:
            return "asleepCore"
        case .asleepDeep:
            return "asleepDeep"
        case .asleepREM:
            return "asleepREM"
        @unknown default:
            return "unknown"
        }
    }
}
