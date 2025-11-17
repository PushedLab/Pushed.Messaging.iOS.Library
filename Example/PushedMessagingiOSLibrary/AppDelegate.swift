import UIKit
import UserNotifications
import PushedMessagingiOSLibrary

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
	UNUserNotificationCenter.current().delegate = self
        
        // Request notification permissions
        requestNotificationPermissions()
        
        // Set to true if you have Notification Service Extension that handles message confirmation
        // This prevents duplicate confirmation from main app
        PushedMessaging.extensionHandlesConfirmation = true
        // PushedMessagingiOSLibrary.clearTokenForTesting()
        // Setup Pushed Library
        // Change these flags to test different modes:
        // - useAPNS: true + enableWebSocket: true = Both APNS and WebSocket
        // - useAPNS: false + enableWebSocket: true = WebSocket only (no APNS)
        // - useAPNS: true + enableWebSocket: false = APNS only (no WebSocket)
        PushedMessaging.setup(
            self, 
            useAPNS: true, 
            enableWebSocket: true
        )

        // Enable background WebSocket BGTasks at launch so iOS can schedule
        print("[Example] Enabling background WebSocket tasks at launch")
        PushedMessaging.enableBackgroundWebSocketTasks()

        PushedMessaging.onWebSocketMessageReceived = { messageJson in
            print("Received WebSocket message: \(messageJson)")
            // Save last push (id + text) for demo UI, ignore duplicates
            let (msgId, text) = Self.extractFromWebSocket(jsonString: messageJson)
            Self.storeLastPush(messageId: msgId, text: text)
            // Return false to let the library handle it exactly like APNS messages
            // UI presentation in foreground is suppressed by the library
            return false
        }
        
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        print("[Example] applicationDidEnterBackground – scheduling BGProcessingTask")
        PushedMessaging.enableBackgroundWebSocketTasks()
        
        // Log pending tasks after 1 second to see what was scheduled
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if #available(iOS 13.0, *) {
                PushedMessaging.logBackgroundTasksStatus()
            }
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("[Example] applicationWillEnterForeground – checking BGProcessingTask status")
        if #available(iOS 13.0, *) {
            PushedMessaging.logBackgroundTasksStatus()
        }
    }
    
    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
            print("Notification permission granted: \(granted)")
        }
    }
    
    // IMPORTANT: This method is required to show notifications when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Display the notification when app is in foreground
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }
    
    // Called when a push is received
    public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
      print("Message: \(userInfo)")
      // Save last push (id + text) for demo UI, ignore duplicates
      let (msgId, text) = AppDelegate.extractFromAPNS(userInfo: userInfo)
      AppDelegate.storeLastPush(messageId: msgId, text: text)
      
      completionHandler(.noData)
    }

    // It is called when you click on the push
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        guard userInfo["aps"] != nil else {
            completionHandler()
            return
        }
        print("Click push: \(userInfo)")
        print("ActionId: \(response.actionIdentifier)")

        // Note: If extensionHandlesConfirmation = true, confirmation is handled by NotificationService extension
        // Otherwise, call confirmMessage here
        if !PushedMessaging.extensionHandlesConfirmation {
            PushedMessaging.confirmMessage(response)
        }
        completionHandler()

    }
    
    // MARK: - Demo helpers for showing last push text (with dedup by messageId)
    private static func storeLastPush(messageId: String?, text: String) {
        let defaults = UserDefaults.standard
        if let mid = messageId, let lastId = defaults.string(forKey: "demo.lastPushId"), lastId == mid {
            // Duplicate message, ignore
            return
        }
        if let mid = messageId {
            defaults.set(mid, forKey: "demo.lastPushId")
        }
        defaults.set(text, forKey: "demo.lastPushText")
        NotificationCenter.default.post(name: Notification.Name("DemoLastPushUpdated"), object: nil)
    }
    // Backward helper if ever used elsewhere
    private static func storeLastPushText(_ text: String) {
        storeLastPush(messageId: nil, text: text)
    }
    
    private static func extractFromAPNS(userInfo: [AnyHashable: Any]) -> (String?, String) {
        let messageId = userInfo["messageId"] as? String
        // Prefer pushedNotification Body; fallback to data string; else compact description
        if let pn = userInfo["pushedNotification"] as? [AnyHashable: Any] {
            let title = (pn["Title"] as? String) ?? ""
            let body = (pn["Body"] as? String) ?? ""
            let combined = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")
            if !combined.isEmpty { return (messageId, combined) }
        }
        if let dataString = userInfo["data"] as? String, !dataString.isEmpty {
            return (messageId, dataString)
        }
        return (messageId, String(describing: userInfo))
    }
    
    private static func extractFromWebSocket(jsonString: String) -> (String?, String) {
        // Try to parse JSON and extract pushedNotification fields or data string
        if let data = jsonString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let json = obj as? [String: Any] {
            let messageId = json["messageId"] as? String
            if let pn = json["pushedNotification"] as? [String: Any] {
                let title = (pn["Title"] as? String) ?? ""
                let body = (pn["Body"] as? String) ?? ""
                let combined = [title, body].filter { !$0.isEmpty }.joined(separator: " — ")
                if !combined.isEmpty { return (messageId, combined) }
            }
            if let ds = json["data"] as? String, !ds.isEmpty {
                return (messageId, ds)
            }
            // Fallback to whole JSON string if nothing suitable
            return (messageId, jsonString)
        }
        return (nil, jsonString)
    }
    // Called when a Pushed library inited
    @objc
    public func isPushedInited(didRecievePushedClientToken pushedToken: String) {
        print("Pushed token received")
    }
    
    // Cleanup when app terminates
    func applicationWillTerminate(_ application: UIApplication) {
        PushedMessaging.cleanup()
    }

}

