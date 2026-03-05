import Foundation
import HealthKit
import CoreLocation

@available(iOS 16.0, *)
public struct HuRouteData {
    public let samples: [[HKQuantitySample]]
    public let locations: [CLLocation]
    
    public init(samples: [[HKQuantitySample]], locations: [CLLocation]) {
        self.samples = samples
        self.locations = locations
    }
    
    public func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        
        let formatter = ISO8601DateFormatter()
        
        var locationsArr: [[String: Any]] = []
        for loc in locations {
            locationsArr.append([
                "latitude": loc.coordinate.latitude,
                "longitude": loc.coordinate.longitude,
                "altitude": loc.altitude,
                "speed": loc.speed,
                "course": loc.course,
                "timestamp": formatter.string(from: loc.timestamp)
            ])
        }
        dict["locations"] = locationsArr
        
        var samplesArr: [[[String: Any]]] = []
        for sampleGroup in samples {
            var groupArr: [[String: Any]] = []
            for sample in sampleGroup {
                // Approximate unit string since we can't perfectly unwrap dynamic formats
                // But most values will be accessible with standard unit strings or HKQuantityType defaults
                var val: Double = 0.0
                var unitStr = "count"
                let typeId = sample.quantityType.identifier
                
                if typeId.contains("Distance") {
                    val = sample.quantity.doubleValue(for: .meter())
                    unitStr = "m"
                } else if typeId.contains("Energy") {
                    val = sample.quantity.doubleValue(for: .kilocalorie())
                    unitStr = "kcal"
                } else if typeId.contains("Speed") {
                    val = sample.quantity.doubleValue(for: HKUnit.meter().unitDivided(by: .second()))
                    unitStr = "m/s"
                } else if typeId.contains("Rate") { // Default typical cases
                    val = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    unitStr = "count/min"
                } else {
                    val = sample.quantity.doubleValue(for: .count())
                }
                
                groupArr.append([
                    "quantityType": typeId,
                    "startDate": formatter.string(from: sample.startDate),
                    "endDate": formatter.string(from: sample.endDate),
                    "value": val,
                    "unit": unitStr
                ])
            }
            if !groupArr.isEmpty {
                samplesArr.append(groupArr)
            }
        }
        dict["samples"] = samplesArr
        
        return dict
    }
}

@available(iOS 16.0, *)
public struct HuWorkout {
    public let distance: HKQuantity?
    public let duration: TimeInterval
    public let sport: HKWorkoutActivityType
    public let start_time: Date
    public let routeData: HuRouteData
    public let deviceActivityId: String
    public let statistics: [HKQuantityType: HKStatistics]
    public let events: [HKWorkoutEvent]?
    public let workoutActivities: [HKWorkoutActivity]?
    public let metadata: [String: Any]?
    
    public init(distance: HKQuantity?, duration: TimeInterval, sport: HKWorkoutActivityType, start_time: Date, routeData: HuRouteData, deviceActivityId: String, statistics: [HKQuantityType: HKStatistics], events: [HKWorkoutEvent]?, workoutActivities: [HKWorkoutActivity]?, metadata: [String: Any]?) {
        self.distance = distance
        self.duration = duration
        self.sport = sport
        self.start_time = start_time
        self.routeData = routeData
        self.deviceActivityId = deviceActivityId
        self.statistics = statistics
        self.events = events
        self.workoutActivities = workoutActivities
        self.metadata = metadata
    }
    
    public func toDict() -> [String: Any]? {
        let formatter = ISO8601DateFormatter()
        var dict: [String: Any] = [:]
        
        dict["deviceActivityId"] = deviceActivityId
        dict["sport"] = sport.name // custom extension needed or rawValue
        dict["start_time"] = formatter.string(from: start_time)
        dict["duration"] = duration
        if let dist = distance {
            dict["distance"] = dist.doubleValue(for: .meter())
        }
        
        // Compute active energy and other simple stats
        var statsDict: [String: Any] = [:]
        if let activeEnergy = statistics[HKQuantityType(.activeEnergyBurned)] {
            if let sum = activeEnergy.sumQuantity() {
                statsDict["activeEnergy"] = ["sum": sum.doubleValue(for: .kilocalorie())]
            }
        }
        if let hr = statistics[HKQuantityType(.heartRate)] {
            var hrDict: [String: Any] = [:]
            if let avg = hr.averageQuantity() { hrDict["average"] = avg.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }
            if let max = hr.maximumQuantity() { hrDict["maximum"] = max.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }
            statsDict["heartRate"] = hrDict
        }
        if let pw = statistics[HKQuantityType(.cyclingPower)] {
            var pwDict: [String: Any] = [:]
            if let avg = pw.averageQuantity() { pwDict["average"] = avg.doubleValue(for: HKUnit.watt()) }
            statsDict["cyclingPower"] = pwDict
        }
        if let rw = statistics[HKQuantityType(.runningPower)] {
            var rwDict: [String: Any] = [:]
            if let avg = rw.averageQuantity() { rwDict["average"] = avg.doubleValue(for: HKUnit.watt()) }
            statsDict["runningPower"] = rwDict
        }
        if let cd = statistics[HKQuantityType(.cyclingCadence)] {
            var cdDict: [String: Any] = [:]
            if let avg = cd.averageQuantity() { cdDict["average"] = avg.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }
            statsDict["cyclingCadence"] = cdDict
        }
        dict["statistics"] = statsDict
        
        dict["routeData"] = routeData.toDict()
        
        var eventsArr: [[String: Any]] = []
        if let evs = events {
            for e in evs {
                eventsArr.append([
                    "type": String(describing: e.type),
                    "timestamp": formatter.string(from: e.dateInterval.start)
                ])
            }
        }
        dict["events"] = eventsArr
        
        // Need to clean metadata for serialization
        var cleanMeta = [String: Any]()
        if let md = metadata {
            for (key, val) in md {
                if let stringVal = val as? String {
                    cleanMeta[key] = stringVal
                } else if let intVal = val as? Int {
                    cleanMeta[key] = intVal
                } else if let doubleVal = val as? Double {
                    cleanMeta[key] = doubleVal
                } else if let boolVal = val as? Bool {
                    cleanMeta[key] = boolVal
                }
                // Handle complex metadata carefully
            }
        }
        dict["metadata"] = cleanMeta
        
        // Include raw JSON representation
        dict["rawJson"] = dict
        
        return dict
    }
    
    public func toJson() -> Data? {
        if let dict = toDict() {
            return try? JSONSerialization.data(withJSONObject: dict, options: [])
        }
        return nil
    }
}
