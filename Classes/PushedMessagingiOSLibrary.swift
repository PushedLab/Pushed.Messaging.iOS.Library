

import Foundation
import UIKit

private typealias ApplicationApnsToken = @convention(c) (Any, Selector, UIApplication, Data) -> Void
private typealias IsPushedInited = @convention(c) (Any, Selector, String) -> Void
private typealias ApplicationRemoteNotification = @convention(c) (Any, Selector, UIApplication, [AnyHashable : Any], @escaping (UIBackgroundFetchResult) -> Void) -> Void

private var gOriginalAppDelegate: AnyClass?
private var gAppDelegateSubClass: AnyClass?



public class PushedMessagingiOSLibrary: NSProxy {
    
    private static var pushedToken: String?
    private static let sdkVersion = "iOS Native 1.0.1"
    private static let operatingSystem = "iOS \(UIDevice.current.systemVersion)"

    /// Return current client token
    public static var clientToken: String? {
        return pushedToken
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

    private static func refreshPushedToken(in object: AnyObject?, apnsToken: String?){
        
        var clientToken = pushedToken
        if(clientToken == nil) {
            clientToken = getSecToken()
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
                    if(pushedToken == nil && UserDefaults.standard.bool(forKey: "pushedMessaging.askPermissions")){
                        PushedMessagingiOSLibrary.requestNotificationPermissions()
                    }
                    if( saveRes) {
                        pushedToken=clientToken
                    }
                    UserDefaults.standard.set(sdkVersion, forKey: "pushedMessaging.sdkVersion")
                    UserDefaults.standard.set(operatingSystem, forKey: "pushedMessaging.operatingSystem")
                    UserDefaults.standard.set(false, forKey: "pushedMessaging.alertsNeedUpdate")
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
      
        let clientToken=getSecToken() ?? ""
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
        if let pusheNotification=userInfo["pushedNotification"] as? [AnyHashable: Any] {
            if let stringUrl = pusheNotification["url"] as? String {
                if let url = URL(string: stringUrl){
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }

        confirmMessageAction(messageId, action: "Click")
        let clientToken=getSecToken() ?? ""
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
        let clientToken=getSecToken() ?? ""
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
