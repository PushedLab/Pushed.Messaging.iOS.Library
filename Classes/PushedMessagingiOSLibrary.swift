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
    /// Stores the last successfully received APNS token as hex string
    private static var lastApnsToken: String?
    private static let sdkVersion = "iOS Native 1.0.1"
    private static let operatingSystem = "iOS \(UIDevice.current.systemVersion)"
    @available(iOS 13.0, *)
    private static var webSocketClient: PushedWebSocketClient?
    
    // Store notification observer tokens for proper cleanup
    private static var backgroundObserver: NSObjectProtocol?
    private static var foregroundObserver: NSObjectProtocol?
    private static var activeObserver: NSObjectProtocol?
    private static var resignActiveObserver: NSObjectProtocol?

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
    
    /// Return APNS enabled status
    public static var isAPNSEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "pushedMessaging.apnsEnabled")
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
    /// This will remove the token from Keychain
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
        
        // Clear in-memory token
        pushedToken = nil
        
        // Stop WebSocket if running
        if #available(iOS 13.0, *) {
            stopWebSocketConnection()
        }
        
        addLog("Token cleared successfully")
    }

    /// Refresh Pushed token with optional applicationId
    /// This will generate a new token with the provided applicationId
    public static func refreshTokenWithApplicationId(_ applicationId: String?) {
        addLog("🔍 DEBUG: refreshTokenWithApplicationId called with: '\(applicationId ?? "nil")'")
        addLog("🔍 DEBUG: applicationId is nil: \(applicationId == nil)")
        addLog("🔍 DEBUG: applicationId isEmpty: \(applicationId?.isEmpty ?? true)")
        addLog("Refreshing token with applicationId: \(applicationId ?? "nil")")
        let tokenToUse = isAPNSEnabled ? lastApnsToken : nil
        if tokenToUse == nil {
            addLog("🔍 DEBUG: No stored APNS token available, deviceSettings will be empty")
        } else {
            addLog("🔍 DEBUG: Using stored APNS token in request")
        }
        refreshPushedToken(in: nil, apnsToken: tokenToUse, applicationId: applicationId)
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

    private static func refreshPushedToken(in object: AnyObject?, apnsToken: String?, applicationId: String? = nil){
        
        addLog("🔍 DEBUG: refreshPushedToken called with applicationId: '\(applicationId ?? "nil")'")
        
        var clientToken = pushedToken
        if(clientToken == nil) {
            clientToken = getSecToken()
        }
        
        var parameters: [String: Any] = ["clientToken": clientToken ?? ""]
        
        // Include applicationId if provided
        if let applicationId = applicationId, !applicationId.isEmpty {
            parameters["applicationId"] = applicationId
            addLog("🔍 DEBUG: Including applicationId in request: \(applicationId)")
            addLog("Including applicationId in request: \(applicationId)")
        } else {
            addLog("🔍 DEBUG: applicationId is nil or empty, not including in request")
            addLog("🔍 DEBUG: applicationId == nil: \(applicationId == nil)")
            addLog("🔍 DEBUG: applicationId?.isEmpty: \(applicationId?.isEmpty ?? true)")
        }
        
        // Include deviceSettings based on APNS enabled state and token availability
        if let apnsToken = apnsToken, isAPNSEnabled {
            // APNS mode - include APNS token
            parameters["deviceSettings"] = [["deviceToken": apnsToken, "transportKind": "Apns"]]
            addLog("Including APNS token in deviceSettings")
        } else {
            // WebSocket-only mode or no APNS token - send empty deviceSettings
            parameters["deviceSettings"] = []
            if isAPNSEnabled {
                addLog("APNS enabled but no token provided - sending empty deviceSettings")
            } else {
                addLog("APNS disabled - sending empty deviceSettings for WebSocket-only mode")
            }
        }
        
            parameters["operatingSystem"] = operatingSystem

        let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")

        parameters["displayPushNotificationsPermission"] = alerts


        parameters["sdkVersion"] = sdkVersion


        let url = URL(string: "https://sub.multipushed.ru/v2/tokens")!
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        addLog("Post Request body: \(parameters)")
        
        // Debug: Show final JSON that will be sent
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: parameters)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                addLog("🔍 DEBUG: Final JSON being sent: \(jsonString)")
            }
        } catch {
            addLog("🔍 DEBUG: Could not serialize parameters to JSON for logging")
        }

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
      
        let clientToken = clientToken ?? getSecToken() ?? ""
        addLog("🔍 DEBUG: confirmMessage using clientToken: \(clientToken.prefix(8))… (length: \(clientToken.count))")
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
        let clientToken = clientToken ?? getSecToken() ?? ""
        addLog("🔍 DEBUG: confirmMessageAction using clientToken: \(clientToken.prefix(8))… (length: \(clientToken.count))")
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
        let clientToken = clientToken ?? getSecToken() ?? ""
        addLog("🔍 DEBUG: confirmMessageAction using clientToken: \(clientToken.prefix(8))… (length: \(clientToken.count))")
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
        
        // Enable APNS by default if not previously set
        if UserDefaults.standard.object(forKey: "pushedMessaging.apnsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "pushedMessaging.apnsEnabled")
        }
        
        pushedToken=nil
        proxyAppDelegate(appDel)
        
        // Register for remote notifications if APNS is enabled
        if isAPNSEnabled {
            UIApplication.shared.registerForRemoteNotifications()
            addLog("APNS registration enabled - registering for remote notifications")
        } else {
            addLog("APNS registration disabled - skipping remote notifications registration")
            // Still request pushed token for WebSocket-only mode
            refreshPushedToken(in: appDel, apnsToken: nil, applicationId: nil)
        }
        
        // Setup application state observers for WebSocket management
        setupApplicationStateObservers()
    }
    
    /// Setup observers for application state changes
    private static func setupApplicationStateObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            addLog("Application entered background - managing WebSocket connection")
            handleAppDidEnterBackground()
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            addLog("Application will enter foreground - restoring WebSocket connection")
            handleAppWillEnterForeground()
        }
        
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            addLog("Application became active - ensuring WebSocket connection")
            handleAppDidBecomeActive()
        }
        
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            addLog("Application will resign active - preparing WebSocket for background")
            handleAppWillResignActive()
        }
    }
    
    /// Handle application entering background
    private static func handleAppDidEnterBackground() {
        if #available(iOS 13.0, *) {
            if UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled") {
                // Don't completely stop WebSocket, but prepare for background
                webSocketClient?.prepareForBackground()
                addLog("WebSocket prepared for background mode")
            }
        }
    }
    
    /// Handle application entering foreground
    private static func handleAppWillEnterForeground() {
        if #available(iOS 13.0, *) {
            if UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled") && clientToken != nil {
                // Restore WebSocket connection
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let client = webSocketClient {
                        client.restoreFromBackground()
                        addLog("WebSocket restored from background")
                    } else {
                        // WebSocket was completely lost, restart it
                        startWebSocketConnection()
                        addLog("WebSocket restarted after background")
                    }
                }
            }
        }
    }
    
    /// Handle application becoming active
    private static func handleAppDidBecomeActive() {
        if #available(iOS 13.0, *) {
            if UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled") && clientToken != nil {
                // Ensure WebSocket is running when app becomes fully active
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if webSocketClient?.status != .connected {
                        addLog("WebSocket not connected when app became active, restarting")
                        restartWebSocketConnection()
                    }
                }
            }
        }
    }
    
    /// Handle application resigning active
    private static func handleAppWillResignActive() {
        // App is about to become inactive (could be going to background or being interrupted)
        addLog("Application will resign active")
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
    
    /// Enable APNS push notifications
    public static func enableAPNS() {
        addLog("APNS enabled")
        UserDefaults.standard.set(true, forKey: "pushedMessaging.apnsEnabled")
        
        // Register for remote notifications if not already registered
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    
    /// Disable APNS push notifications
    public static func disableAPNS() {
        addLog("APNS disabled")
        UserDefaults.standard.set(false, forKey: "pushedMessaging.apnsEnabled")
        
        // Unregister from remote notifications
        DispatchQueue.main.async {
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }
    
    /// Manually check WebSocket connection health
    @available(iOS 13.0, *)
    public static func checkWebSocketHealth() {
        addLog("Checking WebSocket connection health")
        webSocketClient?.checkConnectionState()
    }
    
    /// Get detailed WebSocket diagnostics
    @available(iOS 13.0, *)
    public static func getWebSocketDiagnostics() -> String {
        var diagnostics = "=== WebSocket Diagnostics ===\n"
        diagnostics += "Timestamp: \(Date())\n"
        diagnostics += "WebSocket Enabled: \(UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled"))\n"
        diagnostics += "Client Token Available: \(clientToken != nil)\n"
        diagnostics += "Status: \(webSocketStatus.rawValue)\n"
        
        if let client = webSocketClient {
            diagnostics += "Client Instance: Available\n"
        } else {
            diagnostics += "Client Instance: Nil\n"
        }
        
        diagnostics += "iOS Version: \(UIDevice.current.systemVersion)\n"
        diagnostics += "SDK Version: \(sdkVersion)\n"
        diagnostics += "App State: \(UIApplication.shared.applicationState.rawValue)\n"
        
        return diagnostics
    }
    
    /// Clean up resources and observers
    public static func cleanup() {
        addLog("Cleaning up PushedMessagingiOSLibrary resources")
        
        // Remove notification observers
        if let backgroundObserver = backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let foregroundObserver = foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let activeObserver = activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        if let resignActiveObserver = resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        
        // Stop WebSocket
        if #available(iOS 13.0, *) {
            stopWebSocketConnection()
        }
    }
    
    public static func requestNotificationPermissions(){
        // Only request permissions if APNS is enabled
        guard isAPNSEnabled else {
            addLog("APNS disabled - skipping notification permissions request")
            return
        }
        
        let center = UNUserNotificationCenter.current()
        let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")

        center.requestAuthorization(options: [.alert, .sound, .badge]) { (granted, error) in
            if let error = error {
                addLog("Notification permissions error: \(error)")
                return
            }
            if(granted != alerts){
                UserDefaults.standard.setValue(granted, forKey: "pushedMessaging.alertEnabled")
                UserDefaults.standard.setValue(true, forKey: "pushedMessaging.alertsNeedUpdate")
                refreshPushedToken(in: nil, apnsToken: nil, applicationId: nil)
            }
            addLog("Notification permissions granted: \(granted)")
        }
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
        PushedMessagingiOSLibrary.addLog("APNS token received")
        
        // Only process APNS token if APNS is enabled
        if PushedMessagingiOSLibrary.isAPNSEnabled {
            PushedMessagingiOSLibrary.addLog("APNS enabled - processing token")
            // Store token for future requests
            PushedMessagingiOSLibrary.lastApnsToken = deviceToken.hexString
            PushedMessagingiOSLibrary.refreshPushedToken(in: self, apnsToken: deviceToken.hexString, applicationId: nil)
        } else {
            PushedMessagingiOSLibrary.addLog("APNS disabled - getting client token without APNS token")
            PushedMessagingiOSLibrary.refreshPushedToken(in: self, apnsToken: nil, applicationId: nil)
        }
        
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
        PushedMessagingiOSLibrary.addLog("Received push notification: \(userInfo)")
        
        // Only process push notification if APNS is enabled
        guard PushedMessagingiOSLibrary.isAPNSEnabled else {
            PushedMessagingiOSLibrary.addLog("APNS disabled - skipping push notification processing")
            PushedMessagingiOSLibrary.redirectMessage(application, in: self, userInfo: userInfo, fetchCompletionHandler: completionHandler)
            return
        }
        
        var message = userInfo
        if let data = userInfo["data"] as? String {
            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data.data(using: .utf8)!, options: .mutableContainers) as? [AnyHashable: Any] {
                    message["data"] = jsonResponse
                    PushedMessagingiOSLibrary.addLog("Parsed data: \(jsonResponse)")
                }
            } catch {
                PushedMessagingiOSLibrary.addLog("Data is String, not JSON")
            }
        }
        
        if let messageId = userInfo["messageId"] as? String {
            PushedMessagingiOSLibrary.addLog("Processing message with ID: \(messageId)")
            let alertBody = (userInfo["aps"] as? [AnyHashable: Any])?["alert"]
            let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")
            
            if alerts && ((alertBody as? [AnyHashable: Any]) != nil || (alertBody as? String) != nil) {
                PushedMessagingiOSLibrary.confirmMessageAction(messageId, action: "Show")
            }
            
            PushedMessagingiOSLibrary.confirmMessage(messageId: messageId, application: application, in: self, userInfo: message, fetchCompletionHandler: completionHandler)
        } else {
            PushedMessagingiOSLibrary.addLog("No messageId found in push notification")
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

