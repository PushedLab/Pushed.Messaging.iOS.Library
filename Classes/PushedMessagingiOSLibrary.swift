import Foundation
import UIKit
import UserNotifications

private typealias ApplicationApnsToken = @convention(c) (Any, Selector, UIApplication, Data) -> Void
private typealias IsPushedInited = @convention(c) (Any, Selector, String) -> Void
private typealias ApplicationRemoteNotification = @convention(c) (Any, Selector, UIApplication, [AnyHashable : Any], @escaping (UIBackgroundFetchResult) -> Void) -> Void

private var gOriginalAppDelegate: AnyClass?
private var gAppDelegateSubClass: AnyClass?

public enum PushedServiceStatus: String {
    case connected = "Connected"
    case disconnected = "Disconnected"
    case connecting = "Connecting"
}

/**
 PushedMessagingiOSLibrary - iOS Push Messaging Library with WebSocket support
 
 WebSocket functionality requires iOS 13.0 or later.
 Use `isWebSocketAvailable` to check if WebSocket is supported on the current device.
 
 Example usage:
 
 ```swift
 // Setup the library
 PushedMessagingiOSLibrary.setup(self, askPermissions: true, loggerEnabled: true)
 
 // Check WebSocket availability before enabling
 if PushedMessagingiOSLibrary.isWebSocketAvailable {
     // Enable WebSocket for real-time messaging
     PushedMessagingiOSLibrary.enableWebSocket()
     
     // Set up WebSocket callbacks
     PushedMessagingiOSLibrary.onWebSocketStatusChange = { status in
         print("WebSocket status: \(status.rawValue)")
     }
     
     PushedMessagingiOSLibrary.onWebSocketMessageReceived = { messageJson in
         print("Received WebSocket message: \(messageJson)")
         // Return true if you handled the message, false to show default notification
         return false
     }
 } else {
     print("WebSocket requires iOS 13.0 or later")
 }
 ```
 */
public class PushedMessagingiOSLibrary: NSProxy {
    
    private static var pushedToken: String?
    private static let sdkVersion = "iOS Native 1.0.1"
    private static let operatingSystem = "iOS \(UIDevice.current.systemVersion)"
    private static var appGroupIdentifier = "group.pushed.example"
    @available(iOS 13.0, *)
    private static var webSocketClient: PushedWebSocketClient?

    /// Configure app group identifier for sharing data with extensions
    /// Must be called before setup() if you want to use a different app group
    public static func configureAppGroup(_ identifier: String) {
        appGroupIdentifier = identifier
        addLog("App group identifier set to: \(identifier)")
    }

    /// Set to true if you have a Notification Service Extension that handles message confirmation
    /// This will prevent duplicate confirmation requests from the main app
    public static var extensionHandlesConfirmation: Bool = false

    /// Return current client token
    public static var clientToken: String? {
        return pushedToken
    }
    
    /// Return WebSocket connection status
    public static var webSocketStatus: PushedServiceStatus {
        if #available(iOS 13.0, *) {
            return webSocketClient?.status ?? .disconnected
        } else {
            return .disconnected
        }
    }
    
    /// WebSocket status change callback
    public static var onWebSocketStatusChange: ((PushedServiceStatus) -> Void)?
    
    /// WebSocket message received callback - return true if message was handled
    public static var onWebSocketMessageReceived: ((String) -> Bool)?
    
    /// Check if WebSocket functionality is available on current iOS version
    public static var isWebSocketAvailable: Bool {
        if #available(iOS 13.0, *) {
            return true
        } else {
            return false
        }
    }
    
    private static func addLog(_ event: String){
        print(event)
        if(UserDefaults.standard.bool(forKey: "pushedMessaging.loggerEnabled")){
            let log=UserDefaults.standard.string(forKey: "pushedMessaging.pushedLog") ?? ""
            UserDefaults.standard.set(log+"\(Date()): \(event)\n", forKey: "pushedMessaging.pushedLog")
        }
    }
    
    ///Returns the service log(debug only)
    public static func getLog() -> String {
        return UserDefaults.standard.string(forKey: "pushedMessaging.pushedLog") ?? ""
    }

    /// Clear Pushed token for testing purposes
    /// This will remove the token from both Keychain and UserDefaults
    public static func clearTokenForTesting() {
        addLog("Clearing Pushed token for testing")
        
        // Remove from Keychain
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword]
        query[kSecAttrAccount] = "pushed_token"
        query[kSecAttrService] = "pushed_messaging_service"
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrSynchronizable] = false
        let status = SecItemDelete(query as CFDictionary)
        
        if status == errSecSuccess {
            addLog("Token successfully removed from Keychain")
        } else if status == errSecItemNotFound {
            addLog("Token not found in Keychain")
        } else {
            addLog("Failed to remove token from Keychain: \(status)")
        }
        
        // Remove from UserDefaults
        UserDefaults.standard.removeObject(forKey: "pushedMessaging.clientToken")
        
        // Remove from shared UserDefaults
        if let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            sharedDefaults.removeObject(forKey: "clientToken")
            sharedDefaults.synchronize()
            addLog("Token removed from shared UserDefaults")
        }
        
        // Clear in-memory token
        pushedToken = nil
        
        // Stop WebSocket if running
        if #available(iOS 13.0, *) {
            stopWebSocketConnection()
        }
        
        addLog("Token cleared successfully")
    }

    private static func saveSecToken(_ token:String)->Bool{
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword]
        query[kSecAttrAccount] = "pushed_token"
        query[kSecAttrService] = "pushed_messaging_service"
        query[kSecReturnData] = false
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrSynchronizable] = false
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        query[kSecReturnData] = true
        if status == errSecSuccess {
            SecItemDelete(query as CFDictionary)
        }
        query[kSecValueData] = token.data(using: .utf8)
        status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
        
    }
    private static func getSecToken()->String?{
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword]
        query[kSecAttrAccount] = "pushed_token"
        query[kSecAttrService] = "pushed_messaging_service"
        query[kSecReturnData] = true
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrSynchronizable] = false
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }

    /// Save token to shared UserDefaults for extension access
    private static func saveTokenToSharedDefaults(_ token: String) {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) else {
            addLog("Failed to access shared UserDefaults with app group: \(appGroupIdentifier)")
            return
        }
        
        sharedDefaults.set(token, forKey: "clientToken")
        sharedDefaults.synchronize()
        addLog("Token saved to shared UserDefaults for extension access")
    }
    
    /// Get token from shared UserDefaults
    private static func getTokenFromSharedDefaults() -> String? {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) else {
            addLog("Failed to access shared UserDefaults with app group: \(appGroupIdentifier)")
            return nil
        }
        
        return sharedDefaults.string(forKey: "clientToken")
    }

    private static func refreshPushedToken(in object: AnyObject?, apnsToken: String?){
        
        var clientToken = pushedToken
        if(clientToken == nil) {
            clientToken = getSecToken()
        }
        if(clientToken == nil) {
            clientToken = getTokenFromSharedDefaults()
        }
        if(clientToken == nil) {
            clientToken = UserDefaults.standard.string(forKey: "pushedMessaging.clientToken")
        }
        
        var parameters: [String: Any] = ["clientToken": clientToken ?? ""]
        if(apnsToken != nil) {
            parameters["deviceSettings"]=[["deviceToken": apnsToken, "transportKind": "Apns"]]
        }
        if(UserDefaults.standard.string(forKey: "pushedMessaging.operatingSystem") != operatingSystem){
            parameters["operatingSystem"] = operatingSystem
        }
        let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")

        if(UserDefaults.standard.bool(forKey: "pushedMessaging.alertsNeedUpdate")) {
            parameters["displayPushNotificationsPermission"] = alerts
        }
        if(UserDefaults.standard.string(forKey: "pushedMessaging.sdkVersion") != sdkVersion){
            parameters["sdkVersion"] = sdkVersion
        }

        let url = URL(string: "https://sub.multipushed.ru/v2/tokens")!
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        addLog("Post Request body: \(parameters)")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        } catch let error {
            addLog(error.localizedDescription)
            return
        }
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                addLog("Post Request Error: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                addLog("Invalid Response received from the server")
                return
            }
            guard let responseData = data else {
                addLog("nil Data received from the server")
                return
            }
            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: responseData, options: .mutableContainers) as? [String: Any] {
                    guard let model=jsonResponse["model"] as? [String: Any] else{
                        self.addLog("Some wrong with model")
                        return
                    }
                    guard let clientToken=model["clientToken"] as? String else{
                        self.addLog("Some wrong with clientToken")
                        return
                    }

                    let saveRes=saveSecToken(clientToken)
                    UserDefaults.standard.setValue(clientToken, forKey: "pushedMessaging.clientToken")
                    // Save to shared UserDefaults for extension access
                    saveTokenToSharedDefaults(clientToken)
                    
                    if(pushedToken == nil && UserDefaults.standard.bool(forKey: "pushedMessaging.askPermissions")){
                        PushedMessagingiOSLibrary.requestNotificationPermissions()
                    }
                    if( saveRes) {
                        pushedToken=clientToken
                    }
                    UserDefaults.standard.set(sdkVersion, forKey: "pushedMessaging.sdkVersion")
                    UserDefaults.standard.set(operatingSystem, forKey: "pushedMessaging.operatingSystem")
                    UserDefaults.standard.set(false, forKey: "pushedMessaging.alertsNeedUpdate")
                    
                    // Auto-start WebSocket connection if enabled
                    if UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled") {
                        DispatchQueue.main.async {
                            if #available(iOS 13.0, *) {
                                startWebSocketConnection()
                            } else {
                                addLog("WebSocket requires iOS 13.0 or later")
                            }
                        }
                    }
                    
                    if(object == nil) {
                        return
                    }
                    let methodSelector = #selector(isPushedInited(didRecievePushedClientToken:))
                    guard let method = class_getInstanceMethod(type(of: object!), methodSelector) else {
                        addLog("No original implementation for isPushedInited method. Skipping...")
                        return
                    }
                    let implementationPointer = NSValue(pointer: UnsafePointer(method_getImplementation(method)))
                    let originalImplementation = unsafeBitCast(implementationPointer.pointerValue, to: IsPushedInited.self)
                    originalImplementation(object!, methodSelector, clientToken)
                } else {
                    addLog("data maybe corrupted or in wrong format")
                    throw URLError(.badServerResponse)
                }
            } catch let error {
                addLog(error.localizedDescription)
            }
        }
        // perform the task
        task.resume()
        
    }
    
    public static func confirmMessage(messageId: String, application: UIApplication, in object: AnyObject, userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void){
      
        let clientToken = clientToken ?? getSecToken() ?? getTokenFromSharedDefaults() ?? ""
        let loginString = String(format: "%@:%@", clientToken, messageId).data(using: String.Encoding.utf8)!.base64EncodedString()
        let url = URL(string: "https://pub.multipushed.ru/v2/confirm?transportKind=Apns")!
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(loginString)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                addLog("Post Request Error: \(error.localizedDescription)")
                PushedMessagingiOSLibrary.redirectMessage(application, in: object, userInfo: userInfo, fetchCompletionHandler: completionHandler)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                addLog("\((response as? HTTPURLResponse)?.statusCode ?? 0): Invalid Response received from the server")
                PushedMessagingiOSLibrary.redirectMessage(application, in: object, userInfo: userInfo, fetchCompletionHandler: completionHandler)
                return
            }
            addLog("Message confirm done")
            PushedMessagingiOSLibrary.redirectMessage(application, in: object, userInfo: userInfo, fetchCompletionHandler: completionHandler)
        }
        // perform the task
        task.resume()
        
    }
    public static func confirmMessage(_ clickResponse: UNNotificationResponse){
      
        let userInfo=clickResponse.notification.request.content.userInfo
        guard let messageId=userInfo["messageId"] as? String else{
            return
        }
        if let pushedNotification=userInfo["pushedNotification"] as? [AnyHashable: Any] {
            if let stringUrl = pushedNotification["Url"] as? String {
                if let url = URL(string: stringUrl){
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }

        confirmMessageAction(messageId, action: "Click")
        let clientToken = clientToken ?? getSecToken() ?? getTokenFromSharedDefaults() ?? ""
        let loginString = String(format: "%@:%@", clientToken, messageId).data(using: String.Encoding.utf8)!.base64EncodedString()
        let url = URL(string: "https://pub.multipushed.ru/v2/confirm?transportKind=Apns")!
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(loginString)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                addLog("Post Request Error: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                addLog("\((response as? HTTPURLResponse)?.statusCode ?? 0): Invalid Response received from the server")
                return
            }
            addLog("Message confirm done")
        }
        // perform the task
        task.resume()
        
    }
     public static func confirmMessageAction(_ messageId : String, action : String){
        let clientToken = clientToken ?? getSecToken() ?? getTokenFromSharedDefaults() ?? ""
        let loginString = String(format: "%@:%@", clientToken, messageId).data(using: String.Encoding.utf8)!.base64EncodedString()
        let url = URL(string: "https://api.multipushed.ru/v2/mobile-push/confirm-client-interaction?clientInteraction=\(action)")!
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(loginString)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                self.addLog("Post Request Error: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                self.addLog("\((response as? HTTPURLResponse)?.statusCode ?? 0): Invalid Response received from the server")
                return
            }
            self.addLog("Message confirm action: \(action) done")
        }
        // perform the task
        task.resume()

    }

    ///Init librarry
    public static func setup(_ appDel: UIApplicationDelegate,askPermissions: Bool = true, loggerEnabled: Bool = false) {
        addLog("Start setup")
        
        UserDefaults.standard.setValue(loggerEnabled, forKey: "pushedMessaging.loggerEnabled")
        UserDefaults.standard.setValue(askPermissions, forKey: "pushedMessaging.askPermissions")
        pushedToken=nil
        proxyAppDelegate(appDel)
        UIApplication.shared.registerForRemoteNotifications()
        
    }
    
    /// Start WebSocket connection for real-time push messages
    @available(iOS 13.0, *)
    public static func startWebSocketConnection() {
        guard let token = clientToken else {
            addLog("Cannot start WebSocket: No client token available")
            return
        }
        
        if webSocketClient != nil {
            addLog("WebSocket client already exists, stopping previous connection")
            stopWebSocketConnection()
        }
        
        addLog("Starting WebSocket connection")
        webSocketClient = PushedWebSocketClient(token: token)
        
        webSocketClient?.onStatusChange = { (status: PushedServiceStatus) in
            addLog("WebSocket status changed to: \(status.rawValue)")
            onWebSocketStatusChange?(status)
        }
        
        webSocketClient?.onMessageReceived = { (message: String) in
            addLog("WebSocket message received via handler")
            return onWebSocketMessageReceived?(message) ?? false
        }
        
        webSocketClient?.connect()
    }
    
    /// Stop WebSocket connection
    @available(iOS 13.0, *)
    public static func stopWebSocketConnection() {
        addLog("Stopping WebSocket connection")
        webSocketClient?.disconnect()
        webSocketClient = nil
    }
    
    /// Restart WebSocket connection
    @available(iOS 13.0, *)
    public static func restartWebSocketConnection() {
        addLog("Restarting WebSocket connection")
        stopWebSocketConnection()
        startWebSocketConnection()
    }
    
    /// Enable WebSocket connection (will auto-start when token is available)
    public static func enableWebSocket() {
        addLog("WebSocket enabled")
        UserDefaults.standard.set(true, forKey: "pushedMessaging.webSocketEnabled")
        if clientToken != nil {
            if #available(iOS 13.0, *) {
                startWebSocketConnection()
            } else {
                addLog("WebSocket requires iOS 13.0 or later")
            }
        }
    }
    
    /// Disable WebSocket connection
    public static func disableWebSocket() {
        addLog("WebSocket disabled")
        UserDefaults.standard.set(false, forKey: "pushedMessaging.webSocketEnabled")
        if #available(iOS 13.0, *) {
            stopWebSocketConnection()
        }
    }
    
    public static func requestNotificationPermissions(){

      let center = UNUserNotificationCenter.current()
      //let application = UIApplication.shared
      let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")

      center.requestAuthorization(options: [.alert, .sound, .badge]) { (granted, error) in
          if let error = error {
              addLog("Err: \(error)")
              return
          }
          if(granted != alerts){
              UserDefaults.standard.setValue(granted, forKey: "pushedMessaging.alertEnabled")
              UserDefaults.standard.setValue(true, forKey: "pushedMessaging.alertsNeedUpdate")
              refreshPushedToken(in: nil, apnsToken: nil)
          }
      }
      //application.registerForRemoteNotifications()
    }
    //------------------------------
    private static func proxyAppDelegate(_ appDelegate: UIApplicationDelegate?) {
        guard let appDelegate = appDelegate else {
            addLog("Cannot proxy AppDelegate. Instance is nil.")
            return
        }

        gAppDelegateSubClass = createSubClass(from: appDelegate)
        
    }

    private static func createSubClass(from originalDelegate: UIApplicationDelegate) -> AnyClass? {
        let originalClass = type(of: originalDelegate )
        let newClassName = "\(originalClass)_\(UUID().uuidString)"
        addLog("\(originalClass)")
        guard NSClassFromString(newClassName) == nil else {
            addLog("Cannot create subclass. Subclass already exists.")
            return nil
        }

        guard let subClass = objc_allocateClassPair(originalClass, newClassName, 0) else {
            addLog("Cannot create subclass. Subclass already exists.")
            return nil
        }

        self.createMethodImplementations(in: subClass, withOriginalDelegate: originalDelegate)
        
        guard class_getInstanceSize(originalClass) == class_getInstanceSize(subClass) else {
            addLog("Cannot create subclass. Original class' and subclass' sizes do not match.")
            return nil
        }

        objc_registerClassPair(subClass)
        if object_setClass(originalDelegate, subClass) != nil {
            addLog("Successfully created proxy.")
        }

        return subClass
    }
    private static func createMethodImplementations(
                in subClass: AnyClass,
                withOriginalDelegate originalDelegate: UIApplicationDelegate)
    {
        let originalClass = type(of: originalDelegate)

        let applicationApnsTokeneSelector = #selector(application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        self.proxyInstanceMethod(
            toClass: subClass,
            withSelector: applicationApnsTokeneSelector,
            fromClass: PushedMessagingiOSLibrary.self,
            fromSelector: applicationApnsTokeneSelector,
            withOriginalClass: originalClass)
        
        let applicationRemoteNotification = #selector(application(_:didReceiveRemoteNotification:fetchCompletionHandler:))
        self.proxyInstanceMethod(
            toClass: subClass,
            withSelector: applicationRemoteNotification,
            fromClass: PushedMessagingiOSLibrary.self,
            fromSelector: applicationRemoteNotification,
            withOriginalClass: originalClass)
        
        
    }
    
    
    
    private static func proxyInstanceMethod(
                toClass destinationClass: AnyClass,
                withSelector destinationSelector: Selector,
                fromClass sourceClass: AnyClass,
                fromSelector sourceSelector: Selector,
                withOriginalClass originalClass: AnyClass)
    {
        self.addInstanceMethod(
                    toClass: destinationClass,
                    toSelector: destinationSelector,
                    fromClass: sourceClass,
                    fromSelector: sourceSelector)

    }
    
    private static func addInstanceMethod(
                toClass destinationClass: AnyClass,
                toSelector destinationSelector: Selector,
                fromClass sourceClass: AnyClass,
                fromSelector sourceSelector: Selector)
    {
        let method = class_getInstanceMethod(sourceClass, sourceSelector)!
        let methodImplementation = method_getImplementation(method)
        let methodTypeEncoding = method_getTypeEncoding(method)

        if !class_addMethod(destinationClass, destinationSelector, methodImplementation, methodTypeEncoding) {
            addLog("Cannot copy method to destination selector '\(destinationSelector)' as it already exists.")
        }
    }

    private static func methodImplementation(for selector: Selector, from fromClass: AnyClass) -> IMP? {
            print(fromClass)
            print(selector)
            guard let method = class_getInstanceMethod(fromClass, selector) else {
                return nil
            }

            return method_getImplementation(method)
        }

    private static func redirectMessage(_ application: UIApplication, in object: AnyObject, userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void){
        let methodSelector = #selector(application(_:didReceiveRemoteNotification:fetchCompletionHandler:))
        guard let method = class_getInstanceMethod(type(of: object), methodSelector) else {
            addLog("No original implementation didReceiveRemoteNotification method. Skipping...")
            completionHandler(.noData)
            return
        }
        let implementationPointer = NSValue(pointer: UnsafePointer(method_getImplementation(method)))
        let originalImplementation = unsafeBitCast(implementationPointer.pointerValue, to: ApplicationRemoteNotification.self)
        originalImplementation(object, methodSelector, application, userInfo,completionHandler)
    }
    
    
    
    @objc
    private func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushedMessagingiOSLibrary.addLog("Apns token: \(deviceToken.hexString)")
        PushedMessagingiOSLibrary.refreshPushedToken(in: self, apnsToken: deviceToken.hexString)
        let methodSelector = #selector(application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        guard let method = class_getInstanceMethod(type(of: self), methodSelector) else {
            print("No original implementation for didRegisterForRemoteNotificationsWithDeviceToken method. Skipping...")
            return
        }
        let implementationPointer = NSValue(pointer: UnsafePointer(method_getImplementation(method)))
        let originalImplementation = unsafeBitCast(implementationPointer.pointerValue, to: ApplicationApnsToken.self)
        originalImplementation(self, methodSelector, application, deviceToken)
    }

    @objc
    private func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushedMessagingiOSLibrary.addLog("Message: \(userInfo)")
        var message=userInfo
        if let data=userInfo["data"] as? String {
            do{
                if let jsonResponse = try JSONSerialization.jsonObject(with: data.data(using: .utf8)!, options: .mutableContainers) as? [AnyHashable: Any] {
                    message["data"]=jsonResponse
                    PushedMessagingiOSLibrary.addLog("Data: \(jsonResponse)")
                }
            } catch {
                PushedMessagingiOSLibrary.addLog(" Data is String")
            }
        }
        if let messageId=userInfo["messageId"] as? String {
            PushedMessagingiOSLibrary.addLog("MessageId: \(messageId)")
            let alertBody = (userInfo["aps"] as? [AnyHashable: Any])?["alert"]
            let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")
            if(alerts && ((alertBody as? [AnyHashable: Any]) !=  nil ||  (alertBody as? String) != nil)){
                PushedMessagingiOSLibrary.confirmMessageAction(messageId, action: "Show")
            }
            PushedMessagingiOSLibrary.confirmMessage(messageId: messageId, application: application, in: self, userInfo: message, fetchCompletionHandler: completionHandler)
        }
        else {
            PushedMessagingiOSLibrary.addLog("No messageId")
            PushedMessagingiOSLibrary.redirectMessage(application, in: self, userInfo: message, fetchCompletionHandler: completionHandler)
        }
        
    }
    
    @objc
    private func isPushedInited(didRecievePushedClientToken pushedToken: String) {
        PushedMessagingiOSLibrary.addLog("Pushed token")
    }
    
    
}

extension Data {
    var hexString: String {
        let hexString = map { String(format: "%02.2hhx", $0) }.joined()
      
        return hexString
    }
}

// MARK: - WebSocket Client
@available(iOS 13.0, *)
public class PushedWebSocketClient: NSObject {
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var shouldReconnect = true
    private var reconnectTimer: Timer?
    private var token: String?
    public private(set) var status: PushedServiceStatus = .disconnected
    private var lastMessageId: String?
    
    public var onStatusChange: ((PushedServiceStatus) -> Void)?
    public var onMessageReceived: ((String) -> Bool)?
    
    private static func addLog(_ event: String) {
        print("WebSocket: \(event)")
        if UserDefaults.standard.bool(forKey: "pushedMessaging.loggerEnabled") {
            let log = UserDefaults.standard.string(forKey: "pushedMessaging.pushedLog") ?? ""
            UserDefaults.standard.set(log + "\(Date()): WebSocket: \(event)\n", forKey: "pushedMessaging.pushedLog")
        }
    }
    
    public init(token: String) {
        super.init()
        self.token = token
        self.lastMessageId = UserDefaults.standard.string(forKey: "pushedMessaging.lastMessageId")
        setupSession()
    }
    
    private func setupSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    public func connect() {
        guard let token = token else {
            Self.addLog("No token available for WebSocket connection")
            return
        }
        
        guard let url = URL(string: "wss://sub.pushed.ru/v2/open-websocket/\(token)") else {
            Self.addLog("Invalid WebSocket URL")
            return
        }
        
        disconnect()
        
        Self.addLog("Connecting to WebSocket: \(url.absoluteString)")
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        status = .connecting
        onStatusChange?(.connecting)
        shouldReconnect = true
        
        receiveMessage()
    }
    
    public func disconnect() {
        shouldReconnect = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        
        if status != .disconnected {
            status = .disconnected
            onStatusChange?(.disconnected)
            Self.addLog("WebSocket disconnected")
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                // Continue receiving messages
                self?.receiveMessage()
                
            case .failure(let error):
                Self.addLog("WebSocket receive error: \(error.localizedDescription)")
                self?.handleConnectionLoss()
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let messageString: String
        
        switch message {
        case .string(let text):
            messageString = text
        case .data(let data):
            messageString = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            Self.addLog("Unknown message type received")
            return
        }
        
        Self.addLog("Received message: \(messageString)")
        
        // First check for simple text status messages (like "ONLINE", "OFFLINE")
        let trimmedMessage = messageString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle various status text messages
        var statusString: String? = nil
        switch trimmedMessage.uppercased() {
        case "ONLINE", "CONNECTED":
            statusString = "Connected"
        case "OFFLINE", "DISCONNECTED":
            statusString = "Disconnected"
        case "CONNECTING":
            statusString = "Connecting"
        default:
            break
        }
        
        if let statusString = statusString,
           let newStatus = PushedServiceStatus(rawValue: statusString) {
            if status != newStatus {
                status = newStatus
                onStatusChange?(newStatus)
                Self.addLog("Service status changed to: \(statusString) (from text: \(trimmedMessage))")
            }
            return
        }
        
        // Try to parse as JSON
        guard let data = messageString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.addLog("Message is not JSON and not a known text status: \(messageString)")
            return
        }
        
        // Handle JSON ServiceStatus messages
        if let serviceStatus = json["ServiceStatus"] as? String,
           let newStatus = PushedServiceStatus(rawValue: serviceStatus) {
            if status != newStatus {
                status = newStatus
                onStatusChange?(newStatus)
                Self.addLog("Service status changed to: \(serviceStatus)")
            }
            return
        }
        
        // Handle regular messages with messageId
        guard let messageId = json["messageId"] as? String else {
            Self.addLog("Message without messageId received")
            return
        }
        
        // Skip if this is the same as last message
        if messageId == lastMessageId {
            Self.addLog("Duplicate message ignored: \(messageId)")
            return
        }
        
        // Save last message ID
        lastMessageId = messageId
        UserDefaults.standard.set(messageId, forKey: "pushedMessaging.lastMessageId")
        
        // Try to handle message with custom handler first
        var handled = false
        if let handler = onMessageReceived {
            handled = handler(messageString)
        }
        
        // If not handled, show as background notification
        if !handled {
            showBackgroundNotification(json)
        }
        
        // Don't confirm WebSocket messages - confirmation is only for APNS messages
        // PushedMessagingiOSLibrary.confirmMessageAction(messageId, action: "WebSocketReceived")
    }
    
    private func showBackgroundNotification(_ messageData: [String: Any]) {
        DispatchQueue.main.async {
            // Check if we have notification permissions
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else {
                    Self.addLog("Notification permissions not granted")
                    return
                }
                
                let content = UNMutableNotificationContent()
                
                // Extract notification content
                if let aps = messageData["aps"] as? [String: Any] {
                    // Handle APNS format
                    if let alert = aps["alert"] as? String {
                        content.body = alert
                    } else if let alertDict = aps["alert"] as? [String: Any] {
                        content.title = alertDict["title"] as? String ?? ""
                        content.body = alertDict["body"] as? String ?? ""
                    }
                    
                    if let badge = aps["badge"] as? Int {
                        content.badge = NSNumber(value: badge)
                    }
                    
                    if let sound = aps["sound"] as? String, !sound.isEmpty {
                        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
                    } else {
                        content.sound = .default
                    }
                } else if let pushedNotification = messageData["pushedNotification"] as? [String: Any] {
                    // Handle pushedNotification format
                    content.title = pushedNotification["Title"] as? String ?? "Новое сообщение"
                    content.body = pushedNotification["Body"] as? String ?? "Получено сообщение"
                    content.sound = .default
                    
                    // Handle custom sound if specified
                    if let soundName = pushedNotification["Sound"] as? String, !soundName.isEmpty {
                        content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
                    }
                    
                    Self.addLog("Notification from pushedNotification: \(content.title) - \(content.body)")
                } else {
                    // Handle WebSocket format without aps or pushedNotification
                    content.title = "Новое сообщение"
                    content.sound = .default
                    
                    // Try to get message text from data field
                    if let dataString = messageData["data"] as? String {
                        content.body = dataString
                    } else if let dataDict = messageData["data"] as? [String: Any] {
                        // If data is a dictionary, try to extract meaningful text
                        if let text = dataDict["text"] as? String {
                            content.body = text
                        } else if let message = dataDict["message"] as? String {
                            content.body = message
                        } else {
                            content.body = "Получено новое сообщение через WebSocket"
                        }
                    } else {
                        content.body = "Получено новое сообщение через WebSocket"
                    }
                }
                
                // Add custom data (important for handling clicks)
                content.userInfo = messageData
                
                // Create request
                let identifier = UUID().uuidString
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                
                // Schedule notification
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        Self.addLog("Failed to schedule notification: \(error.localizedDescription)")
                    } else {
                        Self.addLog("Background notification scheduled")
                    }
                }
            }
        }
    }
    
    private func handleConnectionLoss() {
        isConnected = false
        
        if status != .disconnected {
            status = .disconnected
            onStatusChange?(.disconnected)
        }
        
        if shouldReconnect {
            Self.addLog("WebSocket connection lost, scheduling reconnect")
            scheduleReconnect()
        }
    }
    
    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            if self?.shouldReconnect == true {
                Self.addLog("Attempting WebSocket reconnect")
                self?.connect()
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
@available(iOS 13.0, *)
extension PushedWebSocketClient: URLSessionWebSocketDelegate {
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Self.addLog("WebSocket connection opened")
        isConnected = true
        status = .connected
        onStatusChange?(.connected)
        reconnectTimer?.invalidate()
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Self.addLog("WebSocket connection closed with code: \(closeCode.rawValue)")
        handleConnectionLoss()
    }
}

// MARK: - URLSessionDelegate
@available(iOS 13.0, *)
extension PushedWebSocketClient: URLSessionDelegate {
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Self.addLog("WebSocket task completed with error: \(error.localizedDescription)")
            handleConnectionLoss()
        }
    }
}
