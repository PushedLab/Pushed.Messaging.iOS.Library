import Foundation
import UIKit
import UserNotifications

/// APNS registration, token handling and delivery confirmation.
public class APNSService {

    /// Must match the App Group configured in PushedMessagingiOSLibrary
    private let kAppGroupIdentifier = "group.ru.pushed.messaging"

    private(set) var lastApnsToken: String?
    private let addLog: (String) -> Void
    private var appGroupIdentifier: String?

    var onTokenReceived: ((String) -> Void)?
    var onNotificationReceived: ((UIApplication, [AnyHashable: Any], @escaping (UIBackgroundFetchResult) -> Void) -> Void)?
    var getClientToken: (() -> String?)?
    var markMessageAsProcessed: ((String) -> Void)?
    var confirmMessageAction: ((String, String) -> Void)?
    var isMessageProcessed: ((String) -> Bool)?

    /// The App Group copy is authoritative — the extension writes it too.
    public var isEnabled: Bool {
        if let appGroupID = appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            return sharedDefaults.bool(forKey: "pushedMessaging.apnsEnabled")
        }
        return UserDefaults.standard.bool(forKey: "pushedMessaging.apnsEnabled")
    }

    init(logger: @escaping (String) -> Void) {
        self.addLog = logger
        self.appGroupIdentifier = kAppGroupIdentifier
    }

    public func enable() {
        addLog("APNS enabled")
        UserDefaults.standard.set(true, forKey: "pushedMessaging.apnsEnabled")

        if let appGroupID = appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            sharedDefaults.set(true, forKey: "pushedMessaging.apnsEnabled")
            sharedDefaults.synchronize()
            addLog("APNS enabled saved to App Group: \(appGroupID)")
        }

        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    public func disable() {
        addLog("APNS disabled")
        UserDefaults.standard.set(false, forKey: "pushedMessaging.apnsEnabled")

        if let appGroupID = appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupID) {
            sharedDefaults.set(false, forKey: "pushedMessaging.apnsEnabled")
            sharedDefaults.synchronize()
            addLog("APNS disabled saved to App Group: \(appGroupID)")
        }

        DispatchQueue.main.async {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    /// Unregisters and registers again. iOS often hands back the same token —
    /// it only changes when the device state actually changed.
    public func refreshAPNSToken() {
        guard isEnabled else {
            addLog("APNS disabled - cannot refresh token")
            return
        }

        addLog("Refreshing APNS token - unregistering from remote notifications")
        lastApnsToken = nil

        DispatchQueue.main.async { [weak self] in
            UIApplication.shared.unregisterForRemoteNotifications()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.addLog("Re-registering for remote notifications to obtain new token")
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Request notification permissions (needed by APNS *and* by WebSocket-only mode,
    /// which shows local notifications via PushedService.showBackgroundNotification)
    public func requestNotificationPermissions() {
        let webSocketEnabled = UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled")
        guard isEnabled || webSocketEnabled else {
            addLog("APNS and WebSocket both disabled - skipping notification permissions request")
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
                // The server stores the permission flag, so re-register once it flips
                if let token = self?.lastApnsToken {
                    self?.onTokenReceived?(token)
                }
            }
            self?.addLog("Notification permissions granted: \(granted)")
        }
    }
    
    public func handleDeviceToken(_ deviceToken: Data) {
        guard isEnabled else {
            addLog("APNS disabled - ignoring device token")
            return
        }

        addLog("APNS token received")
        addLog("APNS enabled - processing token")

        lastApnsToken = deviceToken.hexString
        onTokenReceived?(deviceToken.hexString)
    }

    public func handleRemoteNotification(_ application: UIApplication, 
                                       userInfo: [AnyHashable: Any], 
                                       fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard isEnabled else {
            addLog("APNS disabled - passing through notification")
            onNotificationReceived?(application, userInfo, completionHandler)
            return
        }
        
        addLog("Received push notification: \(userInfo)")
        
        // Already shown via WebSocket — drop the APNs copy and clear the local one
        if let incomingMsgId = userInfo["messageId"] as? String, 
           isMessageProcessed?(incomingMsgId) ?? false {
            addLog("Duplicate message via APNs detected (messageId: \(incomingMsgId)). Skipping display and removing local WS notification.")
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
    
    
    private func confirmMessage(messageId: String, 
                               application: UIApplication, 
                               userInfo: [AnyHashable: Any], 
                               fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        
        let clientToken = getClientToken?() ?? ""
        addLog("🔍 DEBUG: confirmMessage using clientToken: \(clientToken.prefix(8))… (length: \(clientToken.count))")
        let loginString = String(format: "%@:%@", clientToken, messageId).data(using: String.Encoding.utf8)!.base64EncodedString()
        let url = URL(string: "https://\(PushedMessaging.endpoints.pubHost)/v2/confirm?transportKind=Apns")!
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


extension Data {
    var hexString: String {
        let hexString = map { String(format: "%02.2hhx", $0) }.joined()
        return hexString
    }
}

