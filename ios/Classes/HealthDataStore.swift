import HealthKit
import Foundation

actor HealthDataStore {
    static let shared = HealthDataStore()
    
    private let storageKey = "HealthDataSamples.pending"
    private let maxSamples = 1000
    
    func storeSample(_ sample: HKSample, type: HKSampleType) async {
        guard let sampleDict = HealthKitConverter.convertSampleToJson(sample, type: type) else { return }
        
        var existing = getSamples()
        existing.append(sampleDict)
        
        // Enforce limit
        if existing.count > maxSamples {
            existing = Array(existing.suffix(maxSamples))
        }
        
        UserDefaults.standard.set(existing, forKey: storageKey)
    }
    
    func retrieveAndClearSamples() async -> [[String: Any]] {
        let samples = getSamples()
        UserDefaults.standard.removeObject(forKey: storageKey)
        return samples
    }
    
    private func getSamples() -> [[String: Any]] {
        return UserDefaults.standard.array(forKey: storageKey) as? [[String: Any]] ?? []
    }
}
