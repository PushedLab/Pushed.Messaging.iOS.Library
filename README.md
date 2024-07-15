# Pushed Messaging iOS library

iOS library to use the Pushed Messaging.

To learn more about Pushed Messaging, please visit the [Pushed website](https://pushed.ru)

## Getting Started

1. On iOS, make sure you have correctly configured your app to support push notifications:
You need to add push notifications capability and remote notification background mode.

2. Add this to your podfile: 
```
pod 'PushedMessagingiOSLibrary', :git => 'https://github.com/PushedLab/Pushed.Messaging.iOS.Library.git'
```

3. run "pod install" or "pod update" 

### Implementation

You need to change your AppDelegate
Example: 

```swift

import SwiftUI
import PushedMessagingiOSLibrary

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
	// Setup library
	PushedMessagingiOSLibrary.setup(appDel: self)
        return true
    }
    
    // This function will be called when a push is received
    public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
      print("Message: \(userInfo)")
      completionHandler(.noData)
    }

    //This function will be called when the Pushed library is successfully initialized
    @objc
    public func isPushedInited(didRecievePushedClientToken pushedToken: String) {
      // To send a message to a specific user, you need to know his Client token.
      print("Client token: \(pushedToken)")

    }
}

```



