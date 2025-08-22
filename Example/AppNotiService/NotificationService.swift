import UserNotifications
import Foundation
import Security
import PushedMessagingiOSLibrary

@objc(NotificationService)
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent
        	guard let bestAttemptContent else {
            contentHandler(request.content)
            return
        }

                NSLog("[Extension] didReceiveNotificationRequest")
        
        // Always attempt message delivery confirmation
        if let messageId = request.content.userInfo["messageId"] as? String {
            NSLog("[Extension] Confirming message delivery with ID: \(messageId)")
            PushedMessagingiOSLibrary.confirmDelivery(messageId: messageId)
        } else {
            NSLog("[Extension] No messageId found – cannot confirm delivery")
        }

        // Always send the content to system
        contentHandler(bestAttemptContent)
    }

    override func serviceExtensionTimeWillExpire() {
        // Вызывается прямо перед тем, как система завершит работу расширения.
        // Используйте это как возможность доставить ваш "лучший" вариант измененного контента,
        // в противном случае будет использована исходная полезная нагрузка push-уведомления.
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Keychain Access Methods
    
    /// Получение токена pushed из Keychain
    /*private func getTokenFromKeychain() -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: "pushed_token",
            kSecAttrService: "pushed_messaging_service",
            kSecReturnData: true,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable: false
        ]
        
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        
        guard status == errSecSuccess, let data = ref as? Data else {
            NSLog("[Extension Keychain] Failed to get token from Keychain, status: \(status)")
            return nil
        }
        
        let token = String(data: data, encoding: .utf8)
        NSLog("[Extension Keychain] Successfully retrieved token from Keychain")
        return token
    }*/

    private func confirmMessage(messageId: String) {
        PushedMessagingiOSLibrary.confirmDelivery(messageId: messageId)
    }
} 
