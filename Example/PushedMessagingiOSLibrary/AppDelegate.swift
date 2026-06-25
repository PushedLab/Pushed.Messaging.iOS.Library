import UIKit
import UserNotifications
import PushedMessagingiOSLibrary

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        if #available(iOS 13.0, *) {
            PushedMessaging.registerBackgroundTaskHandlersAtLaunch()
        }
	UNUserNotificationCenter.current().delegate = self
        
        // Request notification permissions
        requestNotificationPermissions()
        
        // Set to true if you have Notification Service Extension that handles message confirmation
        // This prevents duplicate confirmation from main app
        PushedMessaging.extensionHandlesConfirmation = true
        // Show APNs notifications when app is active (for testing)
        PushedMessagingiOSLibrary.showAPNSWhenActive = true
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
            let (msgId, text) = Self.extractFromWebSocket(jsonString: messageJson)
            Self.storeLastPush(messageId: msgId, text: text)

            guard let data = messageJson.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any],
                  let messageId = json["messageId"] as? String else {
                return true
            }

            // Library no longer shows WebSocket notifications — Example handles it in foreground and background.
            Self.showWebSocketNotification(json, identifier: messageId)
            return true
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
        print("Click push: \(userInfo)")
        print("ActionId: \(response.actionIdentifier)")

        if userInfo["aps"] != nil {
            if !PushedMessaging.extensionHandlesConfirmation {
                PushedMessaging.confirmMessage(response)
            }
        } else if let messageId = userInfo["messageId"] as? String {
            PushedMessaging.confirmMessageAction(messageId, action: "Click")
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
    
    private static func showWebSocketNotification(_ messageData: [String: Any], identifier: String) {
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else {
                    print("WebSocket notification skipped: permission not granted")
                    return
                }

                let content = UNMutableNotificationContent()

                if let pushedNotification = messageData["pushedNotification"] as? [String: Any] {
                    content.title = pushedNotification["Title"] as? String ?? "New Message"
                    content.body = pushedNotification["Body"] as? String ?? "You have a new message."
                    content.sound = UNNotificationSound.default()
                    if let soundName = pushedNotification["Sound"] as? String, !soundName.isEmpty {
                        content.sound = UNNotificationSound(named: soundName)
                    }
                } else {
                    content.title = "New Message"
                    if let bodyString = messageData["data"] as? String, !bodyString.isEmpty {
                        content.body = bodyString
                    } else {
                        content.body = "You have a new message via WebSocket."
                    }
                    content.sound = UNNotificationSound.default()
                }

                content.userInfo = messageData

                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        print("Failed to schedule WebSocket notification: \(error.localizedDescription)")
                    } else {
                        print("WebSocket notification scheduled: \(identifier)")
                        PushedMessaging.confirmMessageAction(identifier, action: "Show")
                    }
                }
            }
        }
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

