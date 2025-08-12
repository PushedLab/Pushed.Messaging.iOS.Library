import Foundation
import UIKit

// Type aliases for method signatures
private typealias ApplicationApnsToken = @convention(c) (Any, Selector, UIApplication, Data) -> Void
private typealias ApplicationRemoteNotification = @convention(c) (Any, Selector, UIApplication, [AnyHashable : Any], @escaping (UIBackgroundFetchResult) -> Void) -> Void

/// Handles AppDelegate method swizzling for APNS integration
class AppDelegateProxy: NSObject {
    
    private var originalAppDelegate: AnyClass?
    private var appDelegateSubClass: AnyClass?
    private let apnsService: APNSService
    private let addLog: (String) -> Void
    
    init(apnsService: APNSService, logger: @escaping (String) -> Void) {
        self.apnsService = apnsService
        self.addLog = logger
    }
    
    /// Setup proxy for the app delegate
    func setupProxy(for appDelegate: UIApplicationDelegate?) {
        guard let appDelegate = appDelegate else {
            addLog("Cannot proxy AppDelegate. Instance is nil.")
            return
        }
        
        appDelegateSubClass = createSubClass(from: appDelegate)
    }
    
    // MARK: - Private Methods
    
    private func createSubClass(from originalDelegate: UIApplicationDelegate) -> AnyClass? {
        let originalClass = type(of: originalDelegate)
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
        
        createMethodImplementations(in: subClass, withOriginalDelegate: originalDelegate)
        
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
    
    private func createMethodImplementations(in subClass: AnyClass, withOriginalDelegate originalDelegate: UIApplicationDelegate) {
        let originalClass = type(of: originalDelegate)
        
        let applicationApnsTokenSelector = #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        proxyInstanceMethod(
            toClass: subClass,
            withSelector: applicationApnsTokenSelector,
            fromClass: PushedMessagingiOSLibrary.self,
            fromSelector: #selector(PushedMessagingiOSLibrary.proxyApplication(_:didRegisterForRemoteNotificationsWithDeviceToken:)),
            withOriginalClass: originalClass)
        
        let applicationRemoteNotificationSelector = #selector(UIApplicationDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:))
        proxyInstanceMethod(
            toClass: subClass,
            withSelector: applicationRemoteNotificationSelector,
            fromClass: PushedMessagingiOSLibrary.self,
            fromSelector: #selector(PushedMessagingiOSLibrary.proxyApplication(_:didReceiveRemoteNotification:fetchCompletionHandler:)),
            withOriginalClass: originalClass)
    }
    
    private func proxyInstanceMethod(
        toClass destinationClass: AnyClass,
        withSelector destinationSelector: Selector,
        fromClass sourceClass: AnyClass,
        fromSelector sourceSelector: Selector,
        withOriginalClass originalClass: AnyClass)
    {
        addInstanceMethod(
            toClass: destinationClass,
            toSelector: destinationSelector,
            fromClass: sourceClass,
            fromSelector: sourceSelector)
    }
    
    private func addInstanceMethod(
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
}