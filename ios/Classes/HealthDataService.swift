import HealthKit
import Flutter

class HealthDataService {
    static let shared = HealthDataService()
    private let healthStore = HKHealthStore()
    
    private var anchors: [HKSampleType: HKQueryAnchor] = [:]
    private var anchoredQueries: [HKSampleType: HKAnchoredObjectQuery] = [:]
    private var observers: [HKSampleType: HKObserverQuery] = [:]
    
    private var eventSink: FlutterEventSink?
    private var monitoredTypes: Set<HKSampleType> = []
    private var isBackground = false
    
    func setEventSink(_ sink: FlutterEventSink?) {
        self.eventSink = sink
    }
    
    func startMonitoring(for type: HKSampleType, startDate: Date?) {
        monitoredTypes.insert(type)
        
        // 1. Setup Background observer delivery
        enableBackgroundDelivery(for: type)
        setupObserverQuery(for: type)
        
        // 2. Setup Foreground live anchored streaming
        let start = startDate ?? Date()
        setupAnchoredQuery(for: type, startDate: start)
    }
    
    func stopMonitoring(for type: HKSampleType) {
        if let query = anchoredQueries[type] { healthStore.stop(query) }
        if let query = observers[type] { healthStore.stop(query) }
        healthStore.disableBackgroundDelivery(for: type) { _, _ in }
        
        anchors.removeValue(forKey: type)
        anchoredQueries.removeValue(forKey: type)
        observers.removeValue(forKey: type)
        monitoredTypes.remove(type)
    }
    
    func enterForegroundMode() {
        isBackground = false
    }
    
    func enterBackgroundMode() {
        isBackground = true
    }
    
    private func enableBackgroundDelivery(for type: HKSampleType) {
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { success, error in
            if let error = error {
                print("Failed to enable background delivery for \(type.identifier): \(error.localizedDescription)")
            } else {
                print("Background delivery enabled for \(type.identifier)")
            }
        }
    }
    
    private func setupObserverQuery(for type: HKSampleType) {
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] query, completionHandler, error in
            guard let self = self, error == nil else { return }
            
            // The observer woke us up, now we run an anchored query to actually get the new data
            self.fetchNewDataFromObserverWakeup(for: type, completionHandler: completionHandler)
        }
        
        healthStore.execute(query)
        observers[type] = query
    }
    
    private func setupAnchoredQuery(for type: HKSampleType, startDate: Date) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] query, addedObjects, deletedObjects, newAnchor, error in
            guard let self = self, let added = addedObjects, error == nil else { return }
            self.anchors[type] = newAnchor
            self.handleSamples(added, type: type)
        }
        
        query.updateHandler = { [weak self] query, addedObjects, deletedObjects, newAnchor, error in
            guard let self = self, let added = addedObjects, error == nil else { return }
            self.anchors[type] = newAnchor
            self.handleSamples(added, type: type)
        }
        
        healthStore.execute(query)
        anchoredQueries[type] = query
    }
    
    private func fetchNewDataFromObserverWakeup(for type: HKSampleType, completionHandler: @escaping () -> Void) {
        let anchor = anchors[type]
        
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) { [weak self] query, addedObjects, deletedObjects, newAnchor, error in
            guard let self = self else {
                completionHandler()
                return
            }
            
            if let added = addedObjects, error == nil {
                self.anchors[type] = newAnchor
                self.handleSamples(added, type: type)
            }
            completionHandler()
        }
        
        healthStore.execute(query)
    }
    
    private func handleSamples(_ samples: [HKSample], type: HKSampleType) {
        for sample in samples {
            if isBackground {
                Task {
                    await HealthDataStore.shared.storeSample(sample, type: type)
                }
            } else if let sink = eventSink {
                if let jsonDict = HealthKitConverter.convertSampleToJson(sample, type: type) {
                    DispatchQueue.main.async {
                        sink(jsonDict)
                    }
                }
            }
        }
    }
}
