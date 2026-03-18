//
//  HRVStreamHandler.swift
//  humango_health
//
//  Flutter stream handler for HRV updates. Attaches/detaches event sink to HRVObserverManager.
//

import Flutter

public class HRVStreamHandler: NSObject, FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        HRVObserverManager.shared.attachEventSink(events)
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        HRVObserverManager.shared.attachEventSink(nil)
        return nil
    }
}
