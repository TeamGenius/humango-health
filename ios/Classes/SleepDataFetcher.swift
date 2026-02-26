import HealthKit

class SleepDataFetcher {
    static let shared = SleepDataFetcher()
    private let healthStore = HKHealthStore()
    
    /// Fetches sleep data for the past `N` days and structurally aggregates it by nightly sessions
    func fetchSleepData(pastDays: Int, completion: @escaping ([[String: Any]]) -> Void) {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion([])
            return
        }
        
        // Start date is `pastDays` ago at noon, to ensure we capture full nights
        let calendar = Calendar.current
        let now = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -pastDays, to: now) else {
            completion([])
            return
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false) // Newest first
        
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, results, error in
            
            guard let samples = results as? [HKCategorySample], error == nil else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            // Algorithm: Group distinct samples into "Nightly Sessions"
            // Apple Health sleep samples are generally chronological but can heavily overlap
            let processedSessions = self.aggregateSleepSamples(samples)
            
            DispatchQueue.main.async {
                completion(processedSessions)
            }
        }
        
        healthStore.execute(query)
    }
    
    private func aggregateSleepSamples(_ samples: [HKCategorySample]) -> [[String: Any]] {
        // We will group samples by "Night". The most reliable way to define a night
        // is to shift the calendar day bounds back by ~12 hours (e.g., Noon to Noon).
        // For simplicity, we can group them by the start date's calendar day if it's past 6PM, or previous day if AM.
        
        var sessionsByDate: [String: [HKCategorySample]] = [:]
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        for sample in samples {
            // Determine logical "Night" date. If a sample starts before 12 PM, we credit it to the previous night's sleep.
            var nightDate = sample.startDate
            let hour = calendar.component(.hour, from: nightDate)
            if hour < 12 {
                nightDate = calendar.date(byAdding: .day, value: -1, to: nightDate) ?? nightDate
            }
            
            let dateKey = dateFormatter.string(from: nightDate)
            
            if sessionsByDate[dateKey] == nil {
                sessionsByDate[dateKey] = []
            }
            sessionsByDate[dateKey]?.append(sample)
        }
        
        // Now calculate metrics for each Nightly Session
        var finalResults: [[String: Any]] = []
        
        for (dateKey, nightSamples) in sessionsByDate {
            guard let sessionDate = dateFormatter.date(from: dateKey) else { continue }
            
            var totalInBedSeconds: TimeInterval = 0
            var totalAsleepSeconds: TimeInterval = 0
            var stages: [[String: Any]] = []
            
            for sample in nightSamples {
                guard let sleepStage = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { continue }
                let duration = sample.endDate.timeIntervalSince(sample.startDate)
                
                let stageString: String
                switch sleepStage {
                case .inBed:
                    stageString = "inBed"
                    totalInBedSeconds += duration
                case .asleepUnspecified:
                    stageString = "asleepUnspecified"
                    totalAsleepSeconds += duration
                case .awake:
                    stageString = "awake"
                case .asleepCore:
                    stageString = "asleepCore"
                    totalAsleepSeconds += duration
                case .asleepDeep:
                    stageString = "asleepDeep"
                    totalAsleepSeconds += duration
                case .asleepREM:
                    stageString = "asleepREM"
                    totalAsleepSeconds += duration
                @unknown default:
                    stageString = "unknown"
                }
                
                stages.append([
                    "stage": stageString,
                    "startDate": DateUtils.isoFormatter.string(from: sample.startDate),
                    "endDate": DateUtils.isoFormatter.string(from: sample.endDate)
                ])
            }
            
            // If the user's Apple Watch doesn't track specific stages, they only get `inBed`.
            // Some apps just mirror `inBed` as `asleep` if that's the only data available.
            // But if we have actual asleep data, we calculate score.
            let safeInBed = max(totalInBedSeconds, totalAsleepSeconds) // Prevent >100% bugs if intervals overlap weirdly
            
            var sleepScore: Double = 0.0
            if safeInBed > 0 {
                sleepScore = (totalAsleepSeconds / safeInBed) * 100.0
            }
            
            // Re-sort stages chronologically oldest to newest for the output array
            stages.sort { (a, b) -> Bool in
                let aStr = a["startDate"] as? String ?? ""
                let bStr = b["startDate"] as? String ?? ""
                return aStr < bStr
            }
            
            let sessionDict: [String: Any] = [
                "date": DateUtils.isoFormatter.string(from: sessionDate),
                "totalInBedSeconds": Int(totalInBedSeconds),
                "totalAsleepSeconds": Int(totalAsleepSeconds),
                "sleepScore": min(max(sleepScore, 0.0), 100.0), // Clamp 0-100
                "stages": stages
            ]
            
            finalResults.append(sessionDict)
        }
        
        // Return sorted newest nights first
        finalResults.sort { (a, b) -> Bool in
            let aDate = a["date"] as? String ?? ""
            let bDate = b["date"] as? String ?? ""
            return aDate > bDate
        }
        
        return finalResults
    }
}
