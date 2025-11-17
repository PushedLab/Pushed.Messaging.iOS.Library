import Foundation
import UIKit
import UserNotifications
import BackgroundTasks
import DeviceKit
import CommonCrypto

private typealias IsPushedInited = @convention(c) (Any, Selector, String) -> Void
private typealias ApplicationRemoteNotification = @convention(c) (Any, Selector, UIApplication, [AnyHashable : Any], @escaping (UIBackgroundFetchResult) -> Void) -> Void
private typealias ApplicationApnsToken = @convention(c) (Any, Selector, UIApplication, Data) -> Void
private typealias ApplicationPerformFetch = @convention(c) (Any, Selector, UIApplication, @escaping (UIBackgroundFetchResult) -> Void) -> Void


// MARK: - Constants

/// App Group identifier used for sharing data between main app and extensions
/// Make sure this matches the App Group configured in your project settings
private let kPushedAppGroupIdentifier = "group.ru.pushed.messaging"

/**
 PushedMessaging - iOS Push Messaging Library with WebSocket support
 
 WebSocket functionality requires iOS 13.0 or later.
 Use `isWebSocketAvailable` to check if WebSocket is supported on the current device.
 
 Example usage:
 
 ```swift
 // Setup the library
 PushedMessaging.setup(self, askPermissions: true, loggerEnabled: true)
 
 // Check WebSocket availability before enabling
 if PushedMessaging.isWebSocketAvailable {
     // Enable WebSocket for real-time messaging
     PushedMessaging.enableWebSocket()
     
     // Set up WebSocket callbacks
     PushedMessaging.onWebSocketStatusChange = { status in
         print("WebSocket status: \(status.rawValue)")
     }
     
     PushedMessaging.onWebSocketMessageReceived = { messageJson in
         print("Received WebSocket message: \(messageJson)")
         // Return true if you handled the message, false to show default notification
         return false
     }
 } else {
     print("WebSocket requires iOS 13.0 or later")
 }
 ```
 */
public class PushedMessaging: NSProxy {
    public enum PushedServiceStatus: String {
        case connected = "Connected"
        case disconnected = "Disconnected"
        case connecting = "Connecting"
    }
    private static var pushedToken: String?
    private static let sdkVersion = "iOS Native 1.1.2"
    private static let operatingSystem = "iOS \(UIDevice.current.systemVersion)"
    
    // Services
    private static var apnsService: APNSService?
    private static var appDelegateProxy: AppDelegateProxy?
    @available(iOS 13.0, *)
    private static var pushedService: PushedService?
    // MARK: - NotificationCenter Delegate Proxy (for APNs deduplication)

    private class NotificationCenterProxy: NSObject, UNUserNotificationCenterDelegate {
        weak var original: UNUserNotificationCenterDelegate?

        init(original: UNUserNotificationCenterDelegate?) {
            self.original = original
        }

        // Suppress notifications already handled via WebSocket
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            // Do not show any notification UI when the app is active (open)
            if UIApplication.shared.applicationState == .active {
                PushedMessagingiOSLibrary.addLog("[Delegate] App active - suppressing notification UI")
                completionHandler([])
                return
            }
            // Only handle deduplication if APNS is enabled
            if PushedMessaging.apnsService?.isEnabled ?? false {
                // Differentiate between remote (APNs) and local (WebSocket) notifications
                if notification.request.trigger is UNPushNotificationTrigger {
                    let userInfo = notification.request.content.userInfo
                    if let msgId = userInfo["messageId"] as? String, PushedMessaging.isMessageProcessed(msgId) {
                        PushedMessaging.addLog("[Delegate] Suppressing APNs UI for already processed messageId: \(msgId)")
                        completionHandler([]) // hide UI
                        return
                    }
                }
            }

            // Forward to original delegate if implemented, otherwise present normally
            if let orig = original, orig.responds(to: #selector(userNotificationCenter(_:willPresent:withCompletionHandler:))) {
                orig.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
            } else {
                if #available(iOS 14.0, *) {
                    completionHandler([.banner, .badge, .sound])
                } else {
                    completionHandler([.alert, .badge, .sound])
                }
            }
        }

        // Forward other delegate calls transparently
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
            // Confirm "Click" interaction for the tapped notification
            PushedMessaging.confirmMessage(response)
            
            // Forward the event to the original delegate if it implements the selector
            if let orig = original, orig.responds(to: #selector(userNotificationCenter(_:didReceive:withCompletionHandler:))) {
                orig.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
            } else {
                completionHandler()
            }
        }
    }

    private static var notificationCenterProxy: NotificationCenterProxy?
    private static let mainKey = "Rt9n4BbW7Y97fhUkyygddZ8sr8xPNYaU"
    private static let bgProcessingIdentifier = "ru.pushed.messaging"
    private static let bgRefreshIdentifier = "ru.pushed.messaging.refresh"
    private static var bgTasksEnabled: Bool = true

    // MARK: - Message Deduplication

    /// Maximum number of messageIds to keep for deduplication
    private static let maxStoredMessageIds = 1000

    /// Returns true if the message with the provided `messageId` was already processed (via WebSocket or APNs)
    static func isMessageProcessed(_ messageId: String) -> Bool {
        let processed = UserDefaults.standard.array(forKey: "pushedMessaging.processedMessageIds") as? [String] ?? []
        let already = processed.contains(messageId)
        addLog("[Dedup] Check processed for messageId: \(messageId) → \(already)")
        return already
    }

    /// Marks the message with the provided `messageId` as processed so duplicates wonʼt be shown later
    static func markMessageProcessed(_ messageId: String) {
        var processed = UserDefaults.standard.array(forKey: "pushedMessaging.processedMessageIds") as? [String] ?? []
        processed.append(messageId)
        // Keep only the most recent `maxStoredMessageIds` elements to avoid unbounded growth
        if processed.count > maxStoredMessageIds {
            processed = Array(processed.suffix(maxStoredMessageIds))
        }
        UserDefaults.standard.set(processed, forKey: "pushedMessaging.processedMessageIds")
        addLog("[Dedup] Stored messageId as processed: \(messageId). Total stored: \(processed.count)")
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
            return pushedService?.status ?? .disconnected
        } else {
            return .disconnected
        }
    }
    
    /// Return APNS enabled status
    public static var isAPNSEnabled: Bool {
        return apnsService?.isEnabled ?? false
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
        print("📣 Pushed: \(event)")
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
            pushedService?.stopConnection()
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
        let tokenToUse = (apnsService?.isEnabled ?? false) ? apnsService?.lastApnsToken : nil
        if tokenToUse == nil {
            addLog("🔍 DEBUG: No stored APNS token available, deviceSettings will be empty")
        } else {
            addLog("🔍 DEBUG: Using stored APNS token in request")
        }
        refreshPushedToken(in: nil, apnsToken: tokenToUse, applicationId: applicationId)
    }

    private static func aesEncrypty(_ message:String,key:String,ivkey:String, operation:Int) -> String? {
        var data = message.data(using: .utf8)!
        if operation == kCCDecrypt{
            data=Data(base64Encoded: message)!
        }
        let ivData  = ivkey.data(using: .utf8)!
        let keyData = key.data(using: .utf8)!
        let cryptLength  = size_t(data.count+kCCBlockSizeAES128)
        var cryptData = Data(count:cryptLength)
        let keyLength = size_t(kCCKeySizeAES128)
        let options   = CCOptions(kCCOptionPKCS7Padding)
        var numBytesEncrypted :size_t = 0
        let cryptStatus = cryptData.withUnsafeMutableBytes {cryptBytes in
            data.withUnsafeBytes {dataBytes in
                ivData.withUnsafeBytes {ivBytes in
                    keyData.withUnsafeBytes {keyBytes in
                        CCCrypt(CCOperation(operation),
                                CCAlgorithm(kCCAlgorithmAES),
                                options,
                                keyBytes, keyLength,
                                ivBytes,
                                dataBytes, data.count,
                                cryptBytes, cryptLength,
                                &numBytesEncrypted)
                        }
                    }
                }
            }

            if UInt32(cryptStatus) == UInt32(kCCSuccess) {
                cryptData.removeSubrange(numBytesEncrypted..<cryptData.count)

            } else {
                addLog("🔍 DEBUG: error")
                return nil
            }
        
        if operation == kCCDecrypt{
            return String(data: cryptData, encoding: .utf8)
        }
        return cryptData.base64EncodedString()

    }
    private static func saveSecToken(_ token:String)->Bool{
        addLog("🔍 DEBUG: Save sec token")
        var secToken=aesEncrypty("encrypted:\(token)", key: mainKey, ivkey: "xjPamAwc7QLYQkhm", operation: kCCEncrypt)
        if secToken==nil {
            addLog("🔍 DEBUG: nil token")
           secToken=token
        }
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
        query[kSecValueData] = secToken!.data(using: .utf8)
        status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
        
    }
    private static func getSecToken()->String?{
        addLog("🔍 DEBUG: Get sec token")
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
        let token = String(data: data, encoding: .utf8)
        addLog("🔍 DEBUG: Raw token: \(token)")
        var secToken=aesEncrypty(token!, key: mainKey, ivkey: "xjPamAwc7QLYQkhm", operation: kCCDecrypt)
        if(secToken != nil && secToken!.starts(with: "encrypted:")){
            addLog("🔍 DEBUG: decrypted token: \(secToken)")
            return secToken!.replacingOccurrences(of: "encrypted:", with: "")
        }
        addLog("🔍 DEBUG: token not encrypted")
        saveSecToken(token!)
        return token
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
        if let apnsToken = apnsToken, apnsService?.isEnabled ?? false {
            // APNS mode - include APNS token
            parameters["deviceSettings"] = [["deviceToken": apnsToken, "transportKind": "Apns"]]
            addLog("Including APNS token in deviceSettings")
        } else {
            // WebSocket-only mode or no APNS token - send empty deviceSettings
            parameters["deviceSettings"] = []
            if apnsService?.isEnabled ?? false {
                addLog("APNS enabled but no token provided - sending empty deviceSettings")
            } else {
                addLog("APNS disabled - sending empty deviceSettings for WebSocket-only mode")
            }
        }
        
            parameters["operatingSystem"] = operatingSystem

        let alerts = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")

        parameters["displayPushNotificationsPermission"] = alerts


        parameters["sdkVersion"] = sdkVersion
        
        // Add human-readable device name and hardware model identifier
        parameters["mobileDeviceName"] = Device.current.description


        let url = URL(string: "https://sub.multipushed.ru/v2/tokens")!
        let session = URLSession.shared
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        addLog("Post Request body: \(parameters)")
        addLog("Device name (friendly): \(Device.current.description)")
        
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
                        PushedMessaging.requestNotificationPermissions()
                    }
                    if( saveRes) {
                        pushedToken=clientToken
                    }
                    UserDefaults.standard.set(sdkVersion, forKey: "pushedMessaging.sdkVersion")
                    UserDefaults.standard.set(operatingSystem, forKey: "pushedMessaging.operatingSystem")
                    UserDefaults.standard.set(false, forKey: "pushedMessaging.alertsNeedUpdate")
                    
                    // Also save to App Group
                    if let sharedDefaults = UserDefaults(suiteName: kPushedAppGroupIdentifier) {
                        sharedDefaults.set(sdkVersion, forKey: "pushedMessaging.sdkVersion")
                        sharedDefaults.set(operatingSystem, forKey: "pushedMessaging.operatingSystem")
                        sharedDefaults.set(false, forKey: "pushedMessaging.alertsNeedUpdate")
                        sharedDefaults.synchronize()
                        addLog("Token refresh data saved to App Group: \(kPushedAppGroupIdentifier)")
                    }
                    
                    // Auto-start WebSocket connection if enabled
                    if UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled") {
                        DispatchQueue.main.async {
                            if #available(iOS 13.0, *) {
                                pushedService?.startConnection(with: clientToken)
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
                PushedMessaging.redirectMessage(application, in: object, userInfo: userInfo, fetchCompletionHandler: completionHandler)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode)
            else {
                addLog("\((response as? HTTPURLResponse)?.statusCode ?? 0): Invalid Response received from the server")
                PushedMessaging.redirectMessage(application, in: object, userInfo: userInfo, fetchCompletionHandler: completionHandler)
                return
            }
            addLog("Message confirm done")
            PushedMessaging.redirectMessage(application, in: object, userInfo: userInfo, fetchCompletionHandler: completionHandler)
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

    public static func confirmDelivery(messageId: String) {
        let clientToken = clientToken ?? getSecToken() ?? ""
        addLog("🔍 DEBUG: confirmDelivery using clientToken: \(clientToken.prefix(8))… (length: \(clientToken.count))")
        let loginString = String(format: "%@:%@", clientToken, messageId).data(using: String.Encoding.utf8)!.base64EncodedString()
        guard let url = URL(string: "https://pub.multipushed.ru/v2/confirm?transportKind=Apns") else {
            addLog("Invalid URL for confirmDelivery")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(loginString)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                addLog("confirmDelivery error: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                addLog("confirmDelivery invalid response: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            addLog("confirmDelivery success")
        }
        task.resume()
    }

    ///Initialize library
    /// - Parameters:
    ///   - appDel: Application delegate (usually `self` inside `application(_:didFinishLaunchingWithOptions:)`)
    ///   - askPermissions: Whether to automatically request notification permissions (only if APNS is enabled)
    ///   - loggerEnabled: Enables verbose internal logging (stored in UserDefaults)
    ///   - useAPNS: Enable integration with APNS push-notifications. Pass `false` if your app already handles APNS independently and you want to use **WebSocket-only mode**. 
    ///             When `false`, the library will:
    ///             - NOT intercept APNS delegate methods
    ///             - Call `unregisterForRemoteNotifications()` to stop receiving APNS
    ///             - Allow your app to handle APNS completely independently
    ///   - enableWebSocket: Immediately enable WebSocket support (equivalent to calling `enableWebSocket()` after setup). Defaults to `false` to preserve previous behaviour.
    public static func setup(_ appDel: UIApplicationDelegate,
                             askPermissions: Bool = true,
                             loggerEnabled: Bool = false,
                             useAPNS: Bool = true,
                             enableWebSocket: Bool = false) {
        addLog("Start setup")
        UserDefaults.standard.setValue(loggerEnabled, forKey: "pushedMessaging.loggerEnabled")
        UserDefaults.standard.setValue(askPermissions, forKey: "pushedMessaging.askPermissions")
        // Enable system Background Fetch at minimum interval (app must have UIBackgroundModes: fetch)
        DispatchQueue.main.async {
            UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        }
        
        // Save to App Group
        if let sharedDefaults = UserDefaults(suiteName: kPushedAppGroupIdentifier) {
            addLog("App Group '\(kPushedAppGroupIdentifier)' is configured")
            sharedDefaults.set(loggerEnabled, forKey: "pushedMessaging.loggerEnabled")
            sharedDefaults.set(askPermissions, forKey: "pushedMessaging.askPermissions")
            sharedDefaults.set(useAPNS, forKey: "pushedMessaging.apnsEnabled")
            sharedDefaults.set(enableWebSocket, forKey: "pushedMessaging.webSocketEnabled")
            sharedDefaults.synchronize()
        }
        
        // Initialize services
        apnsService = APNSService(logger: addLog)
        
        if #available(iOS 13.0, *) {
            pushedService = PushedService(logger: addLog)
            
            // Setup PushedService callbacks
            pushedService?.getClientToken = {
                return clientToken ?? getSecToken()
            }
            
            pushedService?.onStatusChange = { status in
                onWebSocketStatusChange?(status)
            }
            
            pushedService?.onMessageReceived = { message in
                return onWebSocketMessageReceived?(message) ?? false
            }
        }
        
        // Setup APNS callbacks
        apnsService?.onTokenReceived = { token in
            refreshPushedToken(in: appDel, apnsToken: token, applicationId: nil)
        }
        
        apnsService?.onNotificationReceived = { application, userInfo, completionHandler in
            redirectMessage(application, in: appDel, userInfo: userInfo, fetchCompletionHandler: completionHandler)
        }
        
        apnsService?.getClientToken = {
            return clientToken ?? getSecToken()
        }
        
        apnsService?.markMessageAsProcessed = { messageId in
            markMessageProcessed(messageId)
        }
        
        apnsService?.confirmMessageAction = { messageId, action in
            confirmMessageAction(messageId, action: action)
        }
        
        apnsService?.isMessageProcessed = { messageId in
            return isMessageProcessed(messageId)
        }
        
        if #available(iOS 13.0, *) {
            /* BGProcessingTask registration disabled for testing — using only BGAppRefreshTask
            BGTaskScheduler.shared.register(forTaskWithIdentifier: bgProcessingIdentifier, using: nil) { task in
                guard let processingTask = task as? BGProcessingTask else { return }

                addLog("BGTask execution started")

                // Stop the socket gracefully if iOS terminates the task early
                processingTask.expirationHandler = {
                    addLog("BGTask expiration handler invoked - stopping WebSocket connection")
                    pushedService?.stopConnection()
                }

                if let token = getSecToken() ?? pushedToken {
                    pushedService?.startConnection(with: token)
                }
                // Keep the job short; iOS prefers quick tasks. Mark complete and reschedule.
                if bgTasksEnabled {
                    scheduleBGProcessing()
                }
                processingTask.setTaskCompleted(success: true)
                addLog("BGTask execution completed")
            }
            */

            // Register BGAppRefresh task to opportunistically wake app and (re)connect WebSocket
            BGTaskScheduler.shared.register(forTaskWithIdentifier: bgRefreshIdentifier, using: nil) { task in
                guard let refreshTask = task as? BGAppRefreshTask else { return }

                addLog("BGAppRefreshTask execution started")

                refreshTask.expirationHandler = {
                    addLog("BGAppRefreshTask expiration handler invoked - stopping WebSocket connection")
                    pushedService?.stopConnection()
                }

                if let token = getSecToken() ?? pushedToken {
                    pushedService?.startConnection(with: token)
                }

                // Keep it short and reschedule for future
                if bgTasksEnabled {
                    scheduleBGAppRefresh()
                }
                refreshTask.setTaskCompleted(success: true)
                addLog("BGAppRefreshTask execution completed")
            }

        } else {
            // Fallback on earlier versions
        }
        
        pushedToken = nil

        if useAPNS {
            // Enable APNS and setup proxy
            apnsService?.enable()
            appDelegateProxy = AppDelegateProxy(apnsService: apnsService!, logger: addLog)
            appDelegateProxy?.setupProxy(for: appDel)
            addLog("APNS registration enabled - registering for remote notifications")
        } else {
            // Disable APNS
            apnsService?.disable()
            addLog("APNS integration disabled - skipping delegate proxy & APNS registration")
            // WebSocket-only mode – запрашиваем токен сразу
            refreshPushedToken(in: appDel, apnsToken: nil, applicationId: nil)
        }
        
        // Install UNUserNotificationCenter delegate proxy for deduplication
        installNotificationCenterProxy()

        // Enable or disable WebSocket based on caller preference
        if enableWebSocket {
            Self.enableWebSocket()
        } else {
            // Explicitly disable WebSocket if not requested
            UserDefaults.standard.set(false, forKey: "pushedMessaging.webSocketEnabled")
            addLog("WebSocket disabled by setup parameter")
            
            // Stop WebSocket if it's currently running
            if #available(iOS 13.0, *) {
                pushedService?.disable()
            }
        }
    }
    

    
    /// Start WebSocket connection for real-time push messages
    @available(iOS 13.0, *)
    public static func startWebSocketConnection() {
        guard let token = clientToken ?? getSecToken() else {
            addLog("Cannot start WebSocket: No client token available")
            return
        }
        
        pushedService?.startConnection(with: token)
    }
    
    /// Stop WebSocket connection
    @available(iOS 13.0, *)
    public static func stopWebSocketConnection() {
        pushedService?.stopConnection()
    }
    
    /// Restart WebSocket connection
    @available(iOS 13.0, *)
    public static func restartWebSocketConnection() {
        pushedService?.restartConnection()
    }
    
    /// Enable WebSocket connection (will auto-start when token is available)
    public static func enableWebSocket() {
        if #available(iOS 13.0, *) {
            pushedService?.enable()
        } else {
            addLog("WebSocket requires iOS 13.0 or later")
        }
    }
    
    /// Disable WebSocket connection
    public static func disableWebSocket() {
        if #available(iOS 13.0, *) {
            pushedService?.disable()
        }
    }
    
    /// Enable APNS push notifications
    public static func enableAPNS() {
        apnsService?.enable()
    }
    
    /// Disable APNS push notifications
    public static func disableAPNS() {
        apnsService?.disable()
    }
    
    /// Manually check WebSocket connection health
    @available(iOS 13.0, *)
    public static func checkWebSocketHealth() {
        pushedService?.checkConnectionHealth()
    }
    
    /// Get detailed WebSocket diagnostics
    @available(iOS 13.0, *)
    public static func getWebSocketDiagnostics() -> String {
        return pushedService?.getDiagnostics() ?? "WebSocket service not available"
    }
    
    /// Clean up resources and observers
    public static func cleanup() {
        addLog("Cleaning up PushedMessaging resources")
        
        // Stop services
        if #available(iOS 13.0, *) {
            pushedService?.stopConnection()
        }
    }
    
    public static func requestNotificationPermissions(){
        apnsService?.requestNotificationPermissions()
    }


    private static func redirectMessage(_ application: UIApplication, in object: AnyObject, userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void){
        let methodSelector = #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))
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
    private func isPushedInited(didRecievePushedClientToken pushedToken: String) {
        PushedMessaging.addLog("Pushed token")
    }
    
    // MARK: - Proxy methods for AppDelegate
    
    @objc
    dynamic func proxyApplication(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushedMessaging.addLog("Proxy: APNS token received")
        // Handle token through APNS service
        PushedMessaging.apnsService?.handleDeviceToken(deviceToken)
        
        // Call original implementation if exists
        let methodSelector = #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        guard let method = class_getInstanceMethod(type(of: self), methodSelector) else {
            PushedMessaging.addLog("No original implementation for didRegisterForRemoteNotificationsWithDeviceToken method. Skipping...")
            return
        }
        let implementationPointer = NSValue(pointer: UnsafePointer(method_getImplementation(method)))
        let originalImplementation = unsafeBitCast(implementationPointer.pointerValue, to: ApplicationApnsToken.self)
        originalImplementation(self, methodSelector, application, deviceToken)
    }
    
    @objc
    dynamic func proxyApplication(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushedMessaging.addLog("Proxy: Remote notification received")
        // Handle notification through APNS service
        PushedMessaging.apnsService?.handleRemoteNotification(application, userInfo: userInfo, fetchCompletionHandler: completionHandler)
    }

    // Intercept Background Fetch and opportunistically (re)connect WebSocket
    @objc
    dynamic func proxyApplication(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushedMessaging.addLog("Proxy: performFetchWithCompletionHandler invoked")
        // Keep work minimal; attempt to ensure WebSocket is connected if enabled
        if #available(iOS 13.0, *) {
            if UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled"), let token = PushedMessaging.getSecToken() ?? PushedMessaging.clientToken {
                PushedMessaging.pushedService?.startConnection(with: token)
            }
        }
        // Finish quickly; system penalizes long or failing fetches
        completionHandler(.noData)
    }
    
    private static func installNotificationCenterProxy() {
        let center = UNUserNotificationCenter.current()
        if notificationCenterProxy == nil {
            notificationCenterProxy = NotificationCenterProxy(original: center.delegate)
            center.delegate = notificationCenterProxy
            addLog("NotificationCenter proxy installed for deduplication")
        }
    }
    
    /// Schedule BGProcessingTask that keeps/restarts WebSocket in background
    @available(iOS 13.0, *)
    private static func scheduleBGProcessing() {
        guard bgTasksEnabled else { return }
        let request = BGProcessingTaskRequest(identifier: bgProcessingIdentifier)
        // Require network to allow WebSocket connection
        request.requiresNetworkConnectivity = true
        // Avoid requiring external power; keep flexible
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            addLog("BGTask scheduled: \(bgProcessingIdentifier)")
        } catch {
            addLog("BGTask schedule failed: \(error.localizedDescription)")
        }
    }

    /// Schedule BGAppRefreshTask to occasionally wake the app for lightweight refresh/reconnect
    @available(iOS 13.0, *)
    private static func scheduleBGAppRefresh() {
        guard bgTasksEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: bgRefreshIdentifier)
        // Ask iOS to run no earlier than 15 minutes from now (minimum interval is system controlled)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            addLog("BGAppRefreshTask scheduled: \(bgRefreshIdentifier)")
        } catch {
            addLog("BGAppRefreshTask schedule failed: \(error.localizedDescription)")
        }
    }

    /// Public toggles for background WebSocket processing
    public static func enableBackgroundWebSocketTasks() {
        bgTasksEnabled = true
        if #available(iOS 13.0, *) {
            // scheduleBGProcessing() // disabled for testing
            scheduleBGAppRefresh()
            // Log pending tasks after scheduling
            logPendingBackgroundTasks()
        }
    }

    public static func disableBackgroundWebSocketTasks() {
        bgTasksEnabled = false
        if #available(iOS 13.0, *) {
            // BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgProcessingIdentifier) // disabled for testing
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgRefreshIdentifier)
            // addLog("BGTask cancelled: \(bgProcessingIdentifier)")
            addLog("BGAppRefreshTask cancelled: \(bgRefreshIdentifier)")
            logPendingBackgroundTasks()
        }
    }
    
    /// Log all pending background tasks for debugging
    @available(iOS 13.0, *)
    private static func logPendingBackgroundTasks() {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            DispatchQueue.main.async {
                addLog("=== Pending Background Tasks ===")
                if requests.isEmpty {
                    addLog("No pending background tasks")
                } else {
                    for (index, request) in requests.enumerated() {
                        let taskType = request is BGProcessingTaskRequest ? "BGProcessingTask" : "BGAppRefreshTask"
                        addLog("Task \(index + 1): \(request.identifier) (\(taskType))")
                        addLog("  - Earliest begin date: \(request.earliestBeginDate?.description ?? "nil")")
                        if let processingRequest = request as? BGProcessingTaskRequest {
                            addLog("  - Requires network: \(processingRequest.requiresNetworkConnectivity)")
                            addLog("  - Requires power: \(processingRequest.requiresExternalPower)")
                        }
                    }
                }
                addLog("=== End Pending Tasks ===")
            }
        }
    }
    
    /// Public method to manually log pending tasks
    @available(iOS 13.0, *)
    public static func logBackgroundTasksStatus() {
        logPendingBackgroundTasks()
    }
}



