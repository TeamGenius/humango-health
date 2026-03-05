//
//  AppLifecycleManager.swift
//  humango_health
//
//  Centralized iOS app lifecycle management.
//  Services subscribe to this manager for foreground/background transitions.
//

import Foundation
import UIKit

// MARK: - AppLifecycleObserver Protocol

/// Protocol for services that need to respond to app lifecycle changes
protocol AppLifecycleObserver: AnyObject {
    func appDidEnterForeground()
    func appDidEnterBackground()
}

// MARK: - AppLifecycleManager

/// Centralized manager for iOS app lifecycle notifications.
/// Services register as observers to receive foreground/background callbacks.
///
/// Usage:
/// ```swift
/// class MyService: AppLifecycleObserver {
///     init() {
///         AppLifecycleManager.shared.addObserver(self)
///     }
///     
///     deinit {
///         AppLifecycleManager.shared.removeObserver(self)
///     }
///     
///     func appDidEnterForeground() {
///         // Switch to foreground mode
///     }
///     
///     func appDidEnterBackground() {
///         // Switch to background mode
///     }
/// }
/// ```
final class AppLifecycleManager {
    
    // MARK: - Singleton
    
    static let shared = AppLifecycleManager()
    
    // MARK: - Properties
    
    /// Current app state
    private(set) var isInForeground: Bool = true
    
    /// Thread-safe observer storage using NSHashTable (weak references)
    private let observers = NSHashTable<AnyObject>.weakObjects()
    private let observerQueue = DispatchQueue(label: "com.humango.AppLifecycleManager.observers", attributes: .concurrent)
    
    // MARK: - Initialization
    
    private init() {
        setupNotificationObservers()
        
        // Set initial state based on current app state
        DispatchQueue.main.async { [weak self] in
            if let state = UIApplication.shared.applicationState as UIApplication.State? {
                self?.isInForeground = (state == .active)
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Setup
    
    private func setupNotificationObservers() {
        let center = NotificationCenter.default
        
        // Foreground notifications
        center.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        center.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Background notifications
        center.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        center.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        print("📱 [AppLifecycleManager] Initialized and observing app lifecycle")
    }
    
    // MARK: - Observer Management
    
    /// Add an observer to receive lifecycle callbacks
    func addObserver(_ observer: AppLifecycleObserver) {
        observerQueue.async(flags: .barrier) { [weak self] in
            self?.observers.add(observer)
            print("📱 [AppLifecycleManager] Added observer: \(type(of: observer))")
        }
    }
    
    /// Remove an observer from lifecycle callbacks
    func removeObserver(_ observer: AppLifecycleObserver) {
        observerQueue.async(flags: .barrier) { [weak self] in
            self?.observers.remove(observer)
            print("📱 [AppLifecycleManager] Removed observer: \(type(of: observer))")
        }
    }
    
    // MARK: - Notification Handlers
    
    @objc private func handleDidBecomeActive() {
        guard !isInForeground else { return }
        isInForeground = true
        print("📱 [AppLifecycleManager] App became active (foreground)")
        notifyObserversForeground()
    }
    
    @objc private func handleWillEnterForeground() {
        // This is called before didBecomeActive
        // We use didBecomeActive as the primary trigger
        print("📱 [AppLifecycleManager] App will enter foreground")
    }
    
    @objc private func handleDidEnterBackground() {
        guard isInForeground else { return }
        isInForeground = false
        print("📱 [AppLifecycleManager] App entered background")
        notifyObserversBackground()
    }
    
    @objc private func handleWillResignActive() {
        // This is called before didEnterBackground (also for interruptions like calls)
        // We use didEnterBackground as the primary trigger for full background transition
        print("📱 [AppLifecycleManager] App will resign active")
    }
    
    // MARK: - Notify Observers
    
    private func notifyObserversForeground() {
        observerQueue.sync {
            let allObservers = observers.allObjects.compactMap { $0 as? AppLifecycleObserver }
            DispatchQueue.main.async {
                for observer in allObservers {
                    observer.appDidEnterForeground()
                }
            }
        }
    }
    
    private func notifyObserversBackground() {
        observerQueue.sync {
            let allObservers = observers.allObjects.compactMap { $0 as? AppLifecycleObserver }
            DispatchQueue.main.async {
                for observer in allObservers {
                    observer.appDidEnterBackground()
                }
            }
        }
    }
}
