import HealthKit

class HealthKitConverter {
    
    static func convertSampleToJson(_ sample: HKSample, type: HKSampleType) -> [String: Any]? {
        var dict: [String: Any] = [
            "type": type.identifier,
            "startDate": ISO8601DateFormatter().string(from: sample.startDate),
            "endDate": ISO8601DateFormatter().string(from: sample.endDate)
        ]
        
        if let sourceApp = sample.sourceRevision.source.bundleIdentifier as String? {
            dict["sourceApp"] = sourceApp
        }
        
        if let sourceDevice = sample.device?.name {
            dict["sourceDevice"] = sourceDevice
        }
        
        if let metadata = sample.metadata {
            // Need to cleanly sanitize metadata into JSON safe types
            var cleanMetadata: [String: Any] = [:]
            for (key, value) in metadata {
                if let str = value as? String { cleanMetadata[key] = str }
                else if let str = value as? NSNumber { cleanMetadata[key] = str }
                else if let boolType = value as? Bool { cleanMetadata[key] = boolType }
            }
            if !cleanMetadata.isEmpty {
                dict["metadata"] = cleanMetadata
            }
        }
        
        if let quantitySample = sample as? HKQuantitySample, let quantityType = type as? HKQuantityType {
            let unit = preferredUnit(for: quantityType)
            let value = quantitySample.quantity.doubleValue(for: unit)
            
            dict["value"] = [
                "numericValue": value,
                "unit": unit.unitString
            ]
            return dict
        }
        
        if let categorySample = sample as? HKCategorySample {
            var catValue: Any = categorySample.value
            
            if categorySample.sampleType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
                if let sleepValue = HKCategoryValueSleepAnalysis(rawValue: categorySample.value) {
                    switch sleepValue {
                    case .inBed: catValue = "inBed"
                    case .asleepUnspecified: catValue = "asleepUnspecified"
                    case .awake: catValue = "awake"
                    case .asleepCore: catValue = "asleepCore"
                    case .asleepDeep: catValue = "asleepDeep"
                    case .asleepREM: catValue = "asleepREM"
                    @unknown default: catValue = "unknown"
                    }
                }
            }
            
            dict["value"] = [
                "categoryValue": catValue
            ]
            return dict
        }
        
        return nil // Unhandled sample type
    }
    
    static func preferredUnit(for quantityType: HKQuantityType) -> HKUnit {
        switch quantityType.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue, 
             HKQuantityTypeIdentifier.restingHeartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
            
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return HKUnit.secondUnit(with: .milli)
            
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return HKUnit.count()
            
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            return HKUnit.kilocalorie()
            
        case HKQuantityTypeIdentifier.bodyMass.rawValue:
            return HKUnit.gramUnit(with: .kilo)
            
        case HKQuantityTypeIdentifier.height.rawValue:
            return HKUnit.meterUnit(with: .centi)
            
        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return HKUnit.percent()
            
        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
            
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
            
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return HKUnit.percent()
            
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return HKUnit.meter()
            
        default:
            return HKUnit.count()
        }
    }
}
