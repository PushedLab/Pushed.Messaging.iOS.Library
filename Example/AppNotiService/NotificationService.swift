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
        
        // 1. Confirm message delivery
        if let messageId = request.content.userInfo["messageId"] as? String {
            NSLog("[Extension] Confirming message delivery with ID: \(messageId)")
            PushedMessaging.confirmDelivery(messageId: messageId)
        } else {
            NSLog("[Extension] No messageId found – cannot confirm delivery")
        }
        
        // 2. Переписываем title/body из pushedNotification (если есть)
        if let pushedNotification = request.content.userInfo["pushedNotification"] as? [String: Any] {
            if let title = pushedNotification["Title"] as? String ?? pushedNotification["title"] as? String {
                bestAttemptContent.title = title
                NSLog("[Extension] Set title from pushedNotification: \(title)")
            }
            if let body = pushedNotification["Body"] as? String ?? pushedNotification["body"] as? String {
                bestAttemptContent.body = body
                NSLog("[Extension] Set body from pushedNotification: \(body)")
            }
        } else {
            NSLog("[Extension] No pushedNotification found, using default aps.alert")
        }
        
        // Always send the content to system
        contentHandler(bestAttemptContent)
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Вызывается прямо перед тем, как система завершит работу расширения.
        // Используйте это как возможность доставить ваш "лучший" вариант измененного контента,
        // в противном случае будет использована исходная полезная нагрузка push-уведомления.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
    
    private func confirmMessage(messageId: String) {
        PushedMessaging.confirmDelivery(messageId: messageId)
    }
}