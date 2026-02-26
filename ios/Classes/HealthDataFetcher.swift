import HealthKit

class HealthDataFetcher {
    static let shared = HealthDataFetcher()
    private let healthStore = HKHealthStore()
    
    func fetchHealthData(
        type: HKSampleType,
        startDate: Date,
        endDate: Date,
        limit: Int?,
        completion: @escaping ([[String: Any]]) -> Void
    ) {
        var allSamples: [[String: Any]] = []
        
        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        
        let limitInt = limit ?? HKObjectQueryNoLimit
        
        let query = HKSampleQuery(
            sampleType: type,
            predicate: predicate,
            limit: limitInt,
            sortDescriptors: [sortDescriptor]
        ) { query, results, error in
            if let samples = results {
                for sample in samples {
                    if let json = HealthKitConverter.convertSampleToJson(sample, type: type) {
                        allSamples.append(json)
                    }
                }
            }
            
            DispatchQueue.main.async {
                completion(allSamples)
            }
        }
        
        healthStore.execute(query)
    }
}
