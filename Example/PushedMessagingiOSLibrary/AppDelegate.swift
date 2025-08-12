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
        PushedMessagingiOSLibrary.extensionHandlesConfirmation = true
        
        // Setup Pushed Library
        // Change these flags to test different modes:
        // - useAPNS: true + enableWebSocket: true = Both APNS and WebSocket
        // - useAPNS: false + enableWebSocket: true = WebSocket only (no APNS)
        // - useAPNS: true + enableWebSocket: false = APNS only (no WebSocket)
        PushedMessagingiOSLibrary.setup(
            self, 
            useAPNS: false, 
            enableWebSocket: true
        )

        PushedMessagingiOSLibrary.onWebSocketMessageReceived = { messageJson in
            print("Received WebSocket message: \(messageJson)")
            
            // Return false to let the library handle it exactly like APNS messages
            // This will automatically show notification and handle clicks through didReceive response
            return false
        }
        
        return true
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
        if !PushedMessagingiOSLibrary.extensionHandlesConfirmation {
            PushedMessagingiOSLibrary.confirmMessage(response)
        }
        completionHandler()

    }
    // Called when a Pushed library inited
    @objc
    public func isPushedInited(didRecievePushedClientToken pushedToken: String) {
        print("Pushed token received")
    }
    
    // Cleanup when app terminates
    func applicationWillTerminate(_ application: UIApplication) {
        PushedMessagingiOSLibrary.cleanup()
    }

}

