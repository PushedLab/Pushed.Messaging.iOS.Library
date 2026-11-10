# Pushed Messaging iOS Library

Полнофункциональная iOS библиотека для работы с Pushed Messaging, поддерживающая как традиционные APNS push-уведомления, так и современные WebSocket соединения для real-time messaging.

[![Version](https://img.shields.io/cocoapods/v/PushedMessagingiOSLibrary.svg?style=flat)](https://cocoapods.org/pods/PushedMessagingiOSLibrary)
[![Platform](https://img.shields.io/cocoapods/p/PushedMessagingiOSLibrary.svg?style=flat)](https://cocoapods.org/pods/PushedMessagingiOSLibrary)

## Возможности

### 📱 APNS Push Notifications
- Автоматическая регистрация устройства для push-уведомлений
- Подтверждение доставки и взаимодействия с сообщениями
- Поддержка rich notifications с изображениями и действиями
- Обработка background notifications

### 🔌 WebSocket Real-time Messaging (iOS 13.0+)
- Постоянное соединение для мгновенной доставки сообщений
- Автоматическое переподключение при потере соединения
- Управление состоянием соединения (фон/активное приложение)
- Обработка сообщений в real-time без задержек

### 📞 VoIP-звонки (PushKit + CallKit)
- Отдельный токен PushKit, транспорт `ApnsVoip`
- Системный экран входящего вызова рисует библиотека
- Callback'и на приём, отклонение и показ вызова
- Выключено по умолчанию

### 🔧 Notification Service Extension
- Автоматическое подтверждение push-уведомлений в фоне
- Безопасное хранение токенов в Keychain
- Работа независимо от основного приложения

### 🔐 Безопасность
- Хранение токенов в iOS Keychain
- Шифрованная передача данных
- Basic Authentication для API запросов

## Установка

### CocoaPods

Добавьте в ваш `Podfile`:

```ruby
pod 'PushedMessagingiOSLibrary', :git => 'https://github.com/PushedLab/Pushed.Messaging.iOS.Library.git'
```

Затем выполните:
```bash
pod install
```

### Требования
- iOS 11.0+
- WebSocket функциональность требует iOS 13.0+
- Xcode 12.0+
- Swift 5.0+

## Быстрый старт

### 1. Настройка основного приложения

```swift
import SwiftUI
import PushedMessagingiOSLibrary

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Настройка делегата для уведомлений
        UNUserNotificationCenter.current().delegate = self
        
// Инициализация библиотеки (упрощённый вызов)
// Режимы:
// - useAPNS: true + enableWebSocket: true   → APNS + WebSocket (оба канала)
// - useAPNS: false + enableWebSocket: true  → Только WebSocket (без APNS)
// - useAPNS: true + enableWebSocket: false  → Только APNS
PushedMessagingiOSLibrary.setup(self, useAPNS: true, enableWebSocket: true)

// Дополнительно: настройка коллбеков WebSocket (iOS 13.0+)
if PushedMessagingiOSLibrary.isWebSocketAvailable { setupWebSocketCallbacks() }
        
        return true
    }
    
    // Получение клиентского токена
    @objc func isPushedInited(didRecievePushedClientToken pushedToken: String) {
        print("Client token: \(pushedToken)")
        // Сохраните токен для отправки сообщений конкретному пользователю
    }
    
    // Обработка входящих push-уведомлений
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("Received push notification: \(userInfo)")
        completionHandler(.newData)
    }
    
    // Обработка клика по уведомлению
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        print("User clicked notification: \(response.notification.request.content.userInfo)")
        
        // Подтверждение взаимодействия с уведомлением
        PushedMessagingiOSLibrary.confirmMessage(response)
        
        completionHandler()
    }
    
    // Настройка WebSocket callbacks
    private func setupWebSocketCallbacks() {
        // Отслеживание статуса соединения
        PushedMessagingiOSLibrary.onWebSocketStatusChange = { status in
            print("WebSocket status: \(status.rawValue)")
        }
        
        // Обработка входящих WebSocket сообщений
        PushedMessagingiOSLibrary.onWebSocketMessageReceived = { messageJson in
            print("WebSocket message received: \(messageJson)")
            
            // Обработайте сообщение в вашем приложении
            // Верните true если сообщение обработано, false для показа стандартного уведомления
            return self.handleWebSocketMessage(messageJson)
        }
    }
    
    private func handleWebSocketMessage(_ messageJson: String) -> Bool {
        // Ваша логика обработки WebSocket сообщений
        do {
            let data = messageJson.data(using: .utf8)!
            let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            // Обработка сообщения...
            
            return true // Сообщение обработано
        } catch {
            print("Error parsing WebSocket message: \(error)")
            return false // Показать стандартное уведомление
        }
    }
}
```

### 📎 Привязка токена к Application ID

Если в вашем аккаунте Pushed создано несколько приложений, вы можете сразу привязать клиентский токен к конкретному приложению. Для этого перед первым запросом токена передайте `applicationId`.

```swift
// Сразу после PushedMessagingiOSLibrary.setup(...)
PushedMessagingiOSLibrary.refreshTokenWithApplicationId("YOUR_APPLICATION_ID")
```

Библиотека отправит параметр `applicationId` в запросе `POST /v2/tokens`, и полученный токен будет мгновенно закреплён за выбранным приложением в системе Pushed.

Если строка пуста или `nil`, будет использовано поведение по умолчанию — токен привяжется к приложению, отмеченному как *Default* в вашем личном кабинете.

---

### 2. Настройка Notification Service Extension (рекомендуется)

#### Создание Extension

1. В Xcode: File → New → Target → Notification Service Extension
2. Замените содержимое `NotificationService.swift` на актуальную реализацию:

```swift
import UserNotifications
import Foundation

@objc(NotificationService)
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Подтверждение доставки сообщения через библиотеку
        if let messageId = request.content.userInfo["messageId"] as? String {
            PushedMessagingiOSLibrary.confirmDelivery(messageId: messageId)
        }

        contentHandler(bestAttemptContent)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // Дополнительный код не требуется — библиотека выполнит подтверждение
}
```

#### Настройка Keychain Sharing

⚠️ **Важно:** Для корректной работы Extension необходимо настроить общий доступ к Keychain:

1. В основном приложении: 
   - Перейдите в **Signing & Capabilities**
   - Добавьте **Keychain Sharing** capability
   - Добавьте keychain group: `$(AppIdentifierPrefix)com.yourcompany.yourapp.shared`

2. В Notification Service Extension:
   - Перейдите в **Signing & Capabilities** 
   - Добавьте **Keychain Sharing** capability
   - Добавьте тот же keychain group: `$(AppIdentifierPrefix)com.yourcompany.yourapp.shared`

Без этой настройки Extension не сможет получить доступ к токену, сохраненному основным приложением.

#### Настройка в основном приложении

```swift
// Указать что Extension обрабатывает подтверждения
PushedMessagingiOSLibrary.extensionHandlesConfirmation = true
```

## WebSocket функциональность

### Проверка доступности

```swift
if PushedMessagingiOSLibrary.isWebSocketAvailable {
    // WebSocket доступен (iOS 13.0+)
    PushedMessagingiOSLibrary.enableWebSocket()
} else {
    print("WebSocket requires iOS 13.0 or later")
}
```

### Управление соединением

```swift
// Включить/отключить WebSocket на лету
PushedMessagingiOSLibrary.enableWebSocket()   // эквивалентно enableWebSocket: true
PushedMessagingiOSLibrary.disableWebSocket()  

// Проверить статус
let status = PushedMessagingiOSLibrary.webSocketStatus
print("Current status: \(status.rawValue)")

// Получить диагностику
if #available(iOS 13.0, *) {
    let diagnostics = PushedMessagingiOSLibrary.getWebSocketDiagnostics()
    print(diagnostics)
}
```

## APNS функциональность

### Управление APNS push-уведомлениями

```swift
// Включить APNS push-уведомления (включено по умолчанию)
PushedMessagingiOSLibrary.enableAPNS()

// Проверить статус APNS
let isEnabled = PushedMessagingiOSLibrary.isAPNSEnabled
print("APNS enabled: \(isEnabled)")
```

### Сценарии использования

**Полный режим (APNS + WebSocket):**
```swift
// Через setup:
PushedMessagingiOSLibrary.setup(self, useAPNS: true, enableWebSocket: true)

// Или включить на лету:
PushedMessagingiOSLibrary.enableAPNS()
if PushedMessagingiOSLibrary.isWebSocketAvailable { PushedMessagingiOSLibrary.enableWebSocket() }
```

**Только WebSocket (без push-уведомлений):**
```swift
// Через setup:
PushedMessagingiOSLibrary.setup(self, useAPNS: false, enableWebSocket: true)

// Или переключить на лету:
PushedMessagingiOSLibrary.disableAPNS()
if PushedMessagingiOSLibrary.isWebSocketAvailable { PushedMessagingiOSLibrary.enableWebSocket() }
```

**Только APNS (классический режим):**
```swift
// Через setup:
PushedMessagingiOSLibrary.setup(self, useAPNS: true, enableWebSocket: false)

// Или переключить на лету:
PushedMessagingiOSLibrary.enableAPNS()
PushedMessagingiOSLibrary.disableWebSocket()
```

### Обработка сообщений

```swift
PushedMessagingiOSLibrary.onWebSocketMessageReceived = { messageJson in
    // Разбор JSON сообщения
    guard let data = messageJson.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    
    // Обработка различных типов сообщений
    switch message["type"] as? String {
    case "notification":
        handleNotificationMessage(message)
        return true
    case "data":
        handleDataMessage(message)
        return true
    default:
        return false // Показать стандартное уведомление
    }
}
```

## VoIP-звонки (PushKit + CallKit)

Отдельный канал для входящих звонков. Работает на собственном токене PushKit, независимом от APNS, и на сервере занимает транспорт `ApnsVoip`.

Выключено по умолчанию — если VoIP не нужен, ничего делать не надо.

### Включение

```swift
PushedMessagingiOSLibrary.setup(
    self,
    useAPNS: true,
    enableWebSocket: true,
    useVoip: true,
    voipCallerName: "Домофон"     // подпись приложения на экране вызова
)
```

Требуется в `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>voip</string>
</array>
```

### Обработка звонка

Экран входящего вызова рисует сама библиотека через CallKit — приложению показывать ничего не нужно. Своя логика подключается тремя callback'ами:

```swift
PushedMessagingiOSLibrary.onIncomingCall = { call in
    // Вызов получен, системный экран уже на экране
}

PushedMessagingiOSLibrary.onCallAnswered = { call in
    // Пользователь нажал «ответить» — здесь поднимается SIP-сессия
    let host  = call.payload["ats_host"]  as? String
    let login = call.payload["sip_login"] as? String
}

PushedMessagingiOSLibrary.onCallDeclined = { call in
    // Отклонён пользователем или истёк таймаут
}
```

### Объект вызова

```swift
public struct PushedCall {
    public let callId: String                 // идентификатор вызова
    public let displayName: String            // что показано на экране вызова
    public let payload: [String: Any]         // данные отправителя, как есть
}
```

`payload` библиотека не разбирает и не валидирует — что отправитель положил в пуш, то и придёт. `callId` берётся из полей `callId` / `call_id`, иначе из `messageId`. `displayName` — из `displayName` или `pushedNotification.Title`.

### Завершение вызова

```swift
PushedMessagingiOSLibrary.reportCallEnded(callId)
```

Снимает системный экран вызова: отбой с другой стороны, ошибка SIP, отмена из приложения.

### Остальные методы

```swift
let token = PushedMessagingiOSLibrary.voipToken        // токен PushKit
let on    = PushedMessagingiOSLibrary.isVoipEnabled

PushedMessagingiOSLibrary.enableVoip(callerName: "Домофон")
PushedMessagingiOSLibrary.disableVoip()
```

### Отчётность

Отправляется автоматически, вызывать ничего не нужно:

| событие | что уходит на сервер |
|---|---|
| пуш доставлен | `confirm?transportKind=ApnsVoip` |
| экран вызова показан | `clientInteraction=Show` |
| нажата «ответить» | `clientInteraction=Click` |
| вызов отклонён | `clientInteraction=Close` |

Завершение уже принятого звонка отдельным событием не считается — `Close` уходит только если до этого не было `Click`.

### Требования к серверу

Для доставки voip-пушей на стороне Pushed нужен **VoIP Services Certificate** и отправка с заголовком `apns-push-type: voip` на топик `<bundle id>.voip`. Обычный push-сертификат на этот топик прав не имеет.

Если контур ещё не знает значение `ApnsVoip`, регистрация токена возвращает 400. Библиотека в этом случае повторяет запрос без voip-записи — APNS и WebSocket продолжают работать, в логе остаётся `[VoIP] Server rejected the request — retrying without the voip transport`.

## API Reference

### Основные методы

```swift
// Инициализация библиотеки (упрощённая форма)
PushedMessagingiOSLibrary.setup(_ appDelegate: UIApplicationDelegate,
                                useAPNS: Bool,
                                enableWebSocket: Bool)

// Инициализация (расширенная форма с дополнительными опциями)
PushedMessagingiOSLibrary.setup(_ appDelegate: UIApplicationDelegate,
                                askPermissions: Bool = true,
                                loggerEnabled: Bool = false,
                                useAPNS: Bool = true,
                                enableWebSocket: Bool = false)

// Получение клиентского токена
let token = PushedMessagingiOSLibrary.clientToken

// Подтверждение сообщения по клику
PushedMessagingiOSLibrary.confirmMessage(_ response: UNNotificationResponse)

// Запрос разрешений на уведомления (если нужно вручную)
PushedMessagingiOSLibrary.requestNotificationPermissions()

// Получение логов (для отладки)
let logs = PushedMessagingiOSLibrary.getLog()
```

### Callback'и

```swift
// Статус WebSocket соединения
PushedMessagingiOSLibrary.onWebSocketStatusChange = { status in
    // .connecting, .connected, .disconnected
}

// Входящие WebSocket сообщения
PushedMessagingiOSLibrary.onWebSocketMessageReceived = { messageJson in
    // Верните true если сообщение обработано
    return false
}
```

## Конфигурация

### Настройки уведомлений

```swift
// Отключить дублирование подтверждений (если используется Extension)
PushedMessagingiOSLibrary.extensionHandlesConfirmation = true

// Включить подробное логирование (пример):
PushedMessagingiOSLibrary.setup(self, askPermissions: true, loggerEnabled: true, useAPNS: true, enableWebSocket: false)
```

### Очистка данных (для тестирования)

```swift
// Очистить токен для тестирования
PushedMessagingiOSLibrary.clearTokenForTesting()
```

## Troubleshooting

### WebSocket проблемы

**WebSocket не подключается:**
1. Проверьте интернет соединение
2. Убедитесь что iOS 13.0+
3. Проверьте что клиентский токен получен
4. Посмотрите диагностику: `getWebSocketDiagnostics()`

**Частые переподключения:**
1. Проверьте стабильность сети
2. Убедитесь что приложение не блокирует фоновые процессы

### APNS проблемы

**Push-уведомления не приходят:**
1. Проверьте capabilities: Push Notifications
2. Убедитесь что сертификаты настроены правильно
3. Проверьте что устройство зарегистрировано для уведомлений

**Дублирование подтверждений:**
1. Установите `extensionHandlesConfirmation = true`
2. Используйте либо Extension, либо основное приложение для подтверждений

### Extension проблемы

**Extension не получает токен:**
1. Убедитесь что основное приложение запускалось хотя бы один раз
2. Проверьте Keychain Sharing в capabilities
3. Убедитесь что Extension имеет доступ к Keychain

## Примеры использования

Полные рабочие примеры доступны в папке `/Example` данного репозитория.

## Лицензия

Этот проект распространяется под лицензией MIT. См. файл `LICENSE` для подробностей.

## Поддержка

Для получения дополнительной информации посетите [сайт Pushed](https://pushed.ru) или создайте issue в данном репозитории.



