import Foundation
import UIKit
import UserNotifications

/// Service responsible for handling all APNS (Apple Push Notification Service) related functionality
public class APNSService {
    
    // MARK: - Constants
    
    /// App Group identifier - must match the one in PushedMessagingiOSLibrary
    private let kAppGroupIdentifier = "group.ru.pushed.messaging"
    
    // MARK: - Properties
    
    /// Stores the last successfully received APNS token as hex string
    private(set) var lastApnsToken: String?
    
    /// Logging closure for service events
    private let addLog: (String) -> Void
    
    /// App Group identifier for sharing data with extensions
    private var appGroupIdentifier: String?
    
    /// Callback for when APNS token is received
    var onTokenReceived: ((String) -> Void)?
    
    /// Callback for handling remote notifications
    var onNotificationReceived: ((UIApplication, [AnyHashable: Any], @escaping (UIBackgroundFetchResult) -> Void) -> Void)?
    
    /// Callback to get client token for message confirmation
    var getClientToken: (() -> String?)?
    
    /// Callback to mark message as processed
    var markMessageAsProcessed: ((String) -> Void)?
    
    /// Callback to confirm message action
    var confirmMessageAction: ((String, String) -> Void)?
    
    /// Callback to check if message is already processed
    var isMessageProcessed: ((String) -> Bool)?
    
    // MARK: - Computed Properties
    
    /// Return APNS enabled status
    public var isEnabled: Bool {
        // First try to read from App Group if available
        if let appGroupID = appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            return sharedDefaults.bool(forKey: "pushedMessaging.apnsEnabled")
        }
        // Fallback to standard UserDefaults
        return UserDefaults.standard.bool(forKey: "pushedMessaging.apnsEnabled")
    }
    
    // MARK: - Initialization
    
    init(logger: @escaping (String) -> Void) {
        self.addLog = logger
        self.appGroupIdentifier = kAppGroupIdentifier
    }
    
    // MARK: - Public Methods
    

    
    /// Enable APNS push notifications
    public func enable() {
        addLog("APNS enabled")
        UserDefaults.standard.set(true, forKey: "pushedMessaging.apnsEnabled")
        
        // Also save to App Group if configured
        if let appGroupID = appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            sharedDefaults.set(true, forKey: "pushedMessaging.apnsEnabled")
            sharedDefaults.synchronize()
            addLog("APNS enabled saved to App Group: \(appGroupID)")
        }
        
        // Register for remote notifications if not already registered
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    
    /// Disable APNS push notifications
    public func disable() {
        addLog("APNS disabled")
        UserDefaults.standard.set(false, forKey: "pushedMessaging.apnsEnabled")
        
        // Also save to App Group if configured
        if let appGroupID = appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            sharedDefaults.set(false, forKey: "pushedMessaging.apnsEnabled")
            sharedDefaults.synchronize()
            addLog("APNS disabled saved to App Group: \(appGroupID)")
        }
        
        // Unregister from remote notifications
        DispatchQueue.main.async {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }
    
    /// Request notification permissions (only if APNS is enabled)
    public func requestNotificationPermissions() {
        guard isEnabled else {
            addLog("APNS disabled - skipping notification permissions request")
            return
        }
        
        let center = UNUserNotificationCenter.current()
        let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")
        
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] (granted, error) in
            if let error = error {
                self?.addLog("Notification permissions error: \(error)")
                return
            }
            if granted != alerts {
                UserDefaults.standard.setValue(granted, forKey: "pushedMessaging.alertEnabled")
                UserDefaults.standard.setValue(true, forKey: "pushedMessaging.alertsNeedUpdate")
                // Trigger token refresh through callback
                if let token = self?.lastApnsToken {
                    self?.onTokenReceived?(token)
                }
            }
            self?.addLog("Notification permissions granted: \(granted)")
        }
    }
    
    /// Handle device token registration
    public func handleDeviceToken(_ deviceToken: Data) {
        guard isEnabled else {
            addLog("APNS disabled - ignoring device token")
            return
        }
        
        addLog("APNS token received")
        addLog("APNS enabled - processing token")
        
        // Store token for future requests
        lastApnsToken = deviceToken.hexString
        
        // Notify about token receipt
        onTokenReceived?(deviceToken.hexString)
    }
    
    /// Handle remote notification
    public func handleRemoteNotification(_ application: UIApplication, 
                                       userInfo: [AnyHashable: Any], 
                                       fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard isEnabled else {
            addLog("APNS disabled - passing through notification")
            onNotificationReceived?(application, userInfo, completionHandler)
            return
        }
        
        addLog("Received push notification: \(userInfo)")
        
        // Prevent showing duplicate notifications if the same message was already received via WebSocket
        if let incomingMsgId = userInfo["messageId"] as? String, 
           isMessageProcessed?(incomingMsgId) ?? false {
            addLog("Duplicate message via APNs detected (messageId: \(incomingMsgId)). Skipping display and removing local WS notification.")
            // Remove possible local notification scheduled by WebSocket with same identifier
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [incomingMsgId])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [incomingMsgId])
            onNotificationReceived?(application, userInfo, completionHandler)
            return
        }
        
        var message = userInfo
        if let data = userInfo["data"] as? String {
            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data.data(using: .utf8)!, options: .mutableContainers) as? [AnyHashable: Any] {
                    message["data"] = jsonResponse
                    addLog("Parsed data: \(jsonResponse)")
                }
            } catch {
                addLog("Data is String, not JSON")
            }
        }
        
        if let messageId = userInfo["messageId"] as? String {
            addLog("Processing message with ID: \(messageId)")
            
            // Mark message as processed to prevent duplicate display via WebSocket
            markMessageAsProcessed?(messageId)
            addLog("[Dedup] messageId \(messageId) marked as processed from APNs path")
            
            let alertBody = (userInfo["aps"] as? [AnyHashable: Any])?["alert"]
            let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")
            
            if alerts && ((alertBody as? [AnyHashable: Any]) != nil || (alertBody as? String) != nil) {
                confirmMessageAction?(messageId, "Show")
            }
            
            confirmMessage(messageId: messageId, application: application, userInfo: message, fetchCompletionHandler: completionHandler)
        } else {
            addLog("No messageId found in push notification")
            onNotificationReceived?(application, message, completionHandler)
        }
    }
    
    // MARK: - Private Methods
    
    private func confirmMessage(messageId: String, 
                               application: UIApplication, 
                               userInfo: [AnyHashable: Any], 
                               fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        
        let clientToken = getClientToken?() ?? ""
        addLog("🔍 DEBUG: confirmMessage using clientToken: \(clientToken.prefix(8))… (length: \(clientToken.count))")
        let loginString = String(format: "%@:%@", clientToken, messageId).data(using: String.Encoding.utf8)!.base64EncodedString()
        let url = URL(string: "https://pub.pushed.dev/v2/confirm?transportKind=Apns")!
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(loginString)", forHTTPHeaderField: "Authorization")
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                self?.addLog("Post Request Error: \(error.localizedDescription)")
                self?.onNotificationReceived?(application, userInfo, completionHandler)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                self?.addLog("\((response as? HTTPURLResponse)?.statusCode ?? 0): Invalid Response received from the server")
                self?.onNotificationReceived?(application, userInfo, completionHandler)
                return
            }
            self?.addLog("Message confirm done")
            self?.onNotificationReceived?(application, userInfo, completionHandler)
        }
        task.resume()
    }
}

// MARK: - Extensions

extension Data {
    var hexString: String {
        let hexString = map { String(format: "%02.2hhx", $0) }.joined()
        return hexString
    }
}

