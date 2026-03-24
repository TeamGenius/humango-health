import Foundation
import HealthKit

/// Single `HKHealthStore` for the process. Apple documents one store instance per app.
/// All reads/writes for sleep, workouts (and routes / activities), and health metrics use this instance.
enum SharedHealthKitStore {
    static let shared: HKHealthStore = HKHealthStore()
}
