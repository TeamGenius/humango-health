import Foundation
import HealthKit

/// Matches the plugin pattern: one `HKHealthStore` per process for all HealthKit access.
enum SharedHealthKitStore {
    static let shared: HKHealthStore = HKHealthStore()
}
