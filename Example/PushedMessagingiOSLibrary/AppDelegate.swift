

import UIKit
import PushedMessagingiOSLibrary

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // Setup Pushed Library
        PushedMessagingiOSLibrary.setup(appDel: self)
        return true
    }
    
    // Called when a push is received
    public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
      print("Message: \(userInfo)")
      
      completionHandler(.noData)
    }

    // Called when a Pushed library inited
    @objc
    public func isPushedInited(didRecievePushedClientToken pushedToken: String) {
      // To send a message to a specific user, you need to know his Client token.
      print("Pushed token: \(pushedToken)")

    }

    

}

