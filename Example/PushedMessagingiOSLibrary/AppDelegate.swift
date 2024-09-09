

import UIKit
import PushedMessagingiOSLibrary

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
	UNUserNotificationCenter.current().delegate = self
        // Setup Pushed Library
        PushedMessagingiOSLibrary.setup(self)
        return true
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

        // You need to call to confirm receipt of the message
        PushedMessagingiOSLibrary.confirmMessage(response)
        completionHandler()

    }
    // Called when a Pushed library inited
    @objc
    public func isPushedInited(didRecievePushedClientToken pushedToken: String) {
      // To send a message to a specific user, you need to know his Client token.
      print("Pushed token: \(pushedToken)")

    }

    

}

