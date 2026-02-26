import HealthKit

extension HKSampleType {
    static func fromIdentifier(_ identifier: String) -> HKSampleType? {
        // Quantity types
        if identifier.hasPrefix("HKQuantityTypeIdentifier") {
            return HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier))
        }
        
        // Category types
        if identifier.hasPrefix("HKCategoryTypeIdentifier") {
            return HKCategoryType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: identifier))
        }
        
        // Workout type
        if identifier == "HKWorkoutType" {
            return HKObjectType.workoutType()
        }
        
        return nil
    }
}
