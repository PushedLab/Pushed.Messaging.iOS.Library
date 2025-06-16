import UserNotifications
import Foundation
import Security

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

        NSLog("[Extension] didReceiveNotificationRequest called with userInfo: \(request.content.userInfo)")

        // Check if APNS is enabled (reading from UserDefaults)
        let isAPNSEnabled = UserDefaults.standard.bool(forKey: "pushedMessaging.alertEnabled")
        NSLog("[Extension] isAPNSEnabled: \(isAPNSEnabled)")                
        if isAPNSEnabled {
            // APNS enabled - process message confirmation
            if let messageId = request.content.userInfo["messageId"] as? String {
                NSLog("[Extension] APNS enabled - confirming message with ID: \(messageId)")
                confirmMessage(messageId: messageId)
            } else {
                NSLog("[Extension] APNS enabled but no messageId found for confirmation")
            }
        } else {
            NSLog("[Extension] APNS disabled - skipping message confirmation")
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
    
    /// Получение токена из Keychain
    private func getTokenFromKeychain() -> String? {
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
    }

    private func confirmMessage(messageId: String) {
        NSLog("[Extension Confirm] Starting message confirmation for messageId: \(messageId)")
        
        // Получаем токен только из Keychain
        guard let clientToken = getTokenFromKeychain(), !clientToken.isEmpty else {
            NSLog("[Extension Confirm] ERROR: clientToken is empty or not found in Keychain")
            return
        }
        
        NSLog("[Extension Confirm] Using client token for authentication")
        
        // Создаем Basic Auth: clientToken:messageId
        let credentials = "\(clientToken):\(messageId)"
        guard let credentialsData = credentials.data(using: .utf8) else {
            NSLog("[Extension Confirm] ERROR: Could not encode credentials")
            return
        }
        let basicAuth = "Basic \(credentialsData.base64EncodedString())"
        
        // Используем эндпоинт v2 из основной библиотеки для консистентности
        guard let url = URL(string: "https://pub.multipushed.ru/v2/confirm?transportKind=Apns") else {
            NSLog("[Extension Confirm] ERROR: Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        
        NSLog("[Extension Confirm] Sending confirmation request to: \(url.absoluteString)")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("[Extension Confirm] Request error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                NSLog("[Extension Confirm] ERROR: No HTTPURLResponse")
                return
            }
            
            let status = httpResponse.statusCode
            let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
            
            if (200..<300).contains(status) {
                NSLog("[Extension Confirm] SUCCESS - Status: \(status), Body: \(responseBody)")
            } else {
                NSLog("[Extension Confirm] ERROR - Status: \(status), Body: \(responseBody)")
            }
        }
        
        task.resume()
        NSLog("[Extension Confirm] Confirmation request sent for messageId: \(messageId)")
    }
} 
