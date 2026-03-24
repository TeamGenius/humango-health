//
//  SleepPayloadObserver.swift
//  humango_health
//
//  KVO-based watcher for the sleep pending payload key in UserDefaults.
//
//  Unlike `UserDefaults.didChangeNotification` (which fires for every write anywhere
//  in the process), KVO on a specific key path fires only when that key changes.
//  When the plugin appends a new sleep payload, Flutter is notified immediately
//  via the EventChannel so it can drain the queue itself.
//
//  EventChannel: "com.humango.health/sleep_payload_updates"
//  Event sent:   Map { "pendingCount": Int }  — count of payloads now in queue.
//

import Flutter
import Foundation

@available(iOS 14.0, *)
final class SleepPayloadObserver: NSObject, FlutterStreamHandler {

    // The UserDefaults key to watch — must match SleepBackgroundDeliveryManager.
    private static let pendingKey = "com.humango.health.sleepPendingLocal"

    private var eventSink: FlutterEventSink?
    private var isObserving = false

    // MARK: - FlutterStreamHandler

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        startObserving()
        debugPrint("🛏️ [SleepPayloadObserver] Flutter listener attached — KVO active")
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stopObserving()
        eventSink = nil
        debugPrint("🛏️ [SleepPayloadObserver] Flutter listener detached — KVO removed")
        return nil
    }

    // MARK: - KVO

    private func startObserving() {
        guard !isObserving else { return }
        UserDefaults.standard.addObserver(
            self,
            forKeyPath: Self.pendingKey,
            options: [.new],
            context: nil
        )
        isObserving = true
    }

    private func stopObserving() {
        guard isObserving else { return }
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.pendingKey)
        isObserving = false
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == Self.pendingKey else { return }

        let count = UserDefaults.standard.stringArray(forKey: Self.pendingKey)?.count ?? 0
        debugPrint("🛏️ [SleepPayloadObserver] KVO fired — pendingCount=\(count)")

        // Always send on main thread (EventChannel requirement).
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(["pendingCount": count])
        }
    }

    deinit {
        stopObserving()
    }
}
