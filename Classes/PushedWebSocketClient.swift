import Foundation
import UIKit
import UserNotifications

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
    private var isInBackground = false
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    
    // Keepalive mechanism
    private var keepaliveTimer: Timer?
    private var connectionHealthTimer: Timer?
    private var lastPongReceived: Date = Date()
    private var pendingPingCount = 0
    private let maxPendingPings = 3
    private let keepaliveInterval: TimeInterval = 30.0 // Send ping every 30 seconds
    private let healthCheckInterval: TimeInterval = 60.0 // Check connection health every minute
    private let pongTimeout: TimeInterval = 10.0 // Expect pong within 10 seconds
    
    public var onStatusChange: ((PushedServiceStatus) -> Void)?
    public var onMessageReceived: ((String) -> Bool)?
    
    private static func addLog(_ event: String) {
        let logMessage = "WebSocket: \(event)"
        print("🔌 \(logMessage)")
        
        // Also log critical events with more emphasis
        if event.contains("connection lost") || event.contains("error") || event.contains("failed") {
            print("🚨 КРИТИЧНО: \(logMessage)")
        }
        
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
    
    deinit {
        Self.addLog("WebSocket client deinitializing")
        disconnect()
        endBackgroundTask()
        stopKeepaliveTimer()
        stopHealthCheckTimer()
    }
    
    private func setupSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60  // Increased for long-lived connections
        config.timeoutIntervalForResource = 300 // Increased for long-lived connections
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    /// Prepare WebSocket for background mode
    public func prepareForBackground() {
        Self.addLog("Preparing WebSocket for background")
        isInBackground = true
        
        // Start background task to keep connection alive briefly
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "WebSocketBackground") {
            // Background task expired
            self.endBackgroundTask()
        }
        
        // Stop keepalive timers in background to save battery
        stopKeepaliveTimer()
        stopHealthCheckTimer()
        
        // Set a shorter reconnect interval for background
        shouldReconnect = true
        
        // Don't disconnect immediately, let iOS handle it naturally
        Self.addLog("WebSocket prepared for background mode")
    }
    
    /// Restore WebSocket from background mode
    public func restoreFromBackground() {
        Self.addLog("Restoring WebSocket from background")
        isInBackground = false
        
        // End background task
        endBackgroundTask()
        
        // Check connection status and reconnect if needed
        if !isConnected || webSocketTask?.state != .running {
            Self.addLog("WebSocket connection lost during background, reconnecting")
            connect()
        } else {
            Self.addLog("WebSocket connection maintained during background")
            // Restart keepalive mechanisms
            startKeepaliveTimer()
            startHealthCheckTimer()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }
    
    public func connect() {
        guard let token = token else {
            Self.addLog("No token available for WebSocket connection")
            return
        }
        
        guard let url = URL(string: "wss://sub.multipushed.ru/v2/open-websocket/\(token)") else {
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
        
        // Stop keepalive mechanisms
        stopKeepaliveTimer()
        stopHealthCheckTimer()
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        
        // End any background task
        endBackgroundTask()
        
        if status != .disconnected {
            status = .disconnected
            onStatusChange?(.disconnected)
            Self.addLog("WebSocket disconnected")
        }
    }
    
    // MARK: - Keepalive Mechanism
    
    private func startKeepaliveTimer() {
        stopKeepaliveTimer()
        
        // Don't start keepalive in background
        guard !isInBackground else {
            Self.addLog("Skipping keepalive timer start - app in background")
            return
        }
        
        Self.addLog("Starting keepalive timer with interval: \(keepaliveInterval)s")
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: keepaliveInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }
    
    private func stopKeepaliveTimer() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        pendingPingCount = 0
        Self.addLog("Keepalive timer stopped")
    }
    
    private func startHealthCheckTimer() {
        stopHealthCheckTimer()
        
        // Don't start health check in background
        guard !isInBackground else {
            Self.addLog("Skipping health check timer start - app in background")
            return
        }
        
        Self.addLog("Starting connection health check timer")
        connectionHealthTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            self?.checkConnectionHealth()
        }
    }
    
    private func stopHealthCheckTimer() {
        connectionHealthTimer?.invalidate()
        connectionHealthTimer = nil
        Self.addLog("Health check timer stopped")
    }
    
    private func sendPing() {
        guard isConnected, let webSocketTask = webSocketTask else {
            Self.addLog("❌ Не могу отправить ping: WebSocket не подключен")
            return
        }
        
        // Check if we have too many pending pings
        if pendingPingCount >= maxPendingPings {
            Self.addLog("💀 PING: WebSocket МЕРТВ! Слишком много неотвеченных ping (\(pendingPingCount))")
            handleConnectionLoss()
            return
        }
        
        let pingData = "ping".data(using: .utf8) ?? Data()
        let pingMessage = URLSessionWebSocketTask.Message.data(pingData)
        
        webSocketTask.send(pingMessage) { [weak self] error in
            if let error = error {
                Self.addLog("💀 PING ПРОВАЛИЛСЯ: \(error.localizedDescription)")
                self?.handleConnectionLoss()
            } else {
                self?.pendingPingCount += 1
                Self.addLog("📤 Ping отправлен, неотвеченных ping: \(self?.pendingPingCount ?? 0)")
            }
        }
    }
    
    private func handlePong() {
        lastPongReceived = Date()
        pendingPingCount = max(0, pendingPingCount - 1)
        Self.addLog("Pong received, pending pings: \(pendingPingCount)")
    }
    
    private func checkConnectionHealth() {
        guard isConnected else {
            Self.addLog("🏥 Проверка здоровья: Соединение неактивно")
            return
        }
        
        // First check the actual WebSocket task state
        checkConnectionState()
        
        // If connection was lost during state check, return
        guard isConnected else {
            return
        }
        
        let timeSinceLastPong = Date().timeIntervalSince(lastPongReceived)
        
        if timeSinceLastPong > (keepaliveInterval * 2 + pongTimeout) {
            Self.addLog("💀 ЗДОРОВЬЕ: WebSocket МЕРТВ! Нет pong уже \(timeSinceLastPong)с")
            handleConnectionLoss()
            return
        }
        
        if pendingPingCount >= maxPendingPings {
            Self.addLog("💀 ЗДОРОВЬЕ: WebSocket МЕРТВ! Слишком много неотвеченных ping (\(pendingPingCount))")
            handleConnectionLoss()
            return
        }
        
        Self.addLog("💚 Здоровье OK: последний pong \(timeSinceLastPong)с назад, pending pings: \(pendingPingCount)")
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
            
            // Check if this is a pong response
            if messageString.lowercased().contains("pong") || data == "pong".data(using: .utf8) {
                handlePong()
                return
            }
        @unknown default:
            Self.addLog("Unknown message type received")
            return
        }
        
        // Check if this is a simple pong text response
        let trimmedMessage = messageString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMessage.lowercased() == "pong" {
            handlePong()
            return
        }
        
        Self.addLog("Received message: \(messageString)")
        
        // First check for simple text status messages (like "ONLINE", "OFFLINE")
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
        
        Self.addLog("Processing WebSocket message with ID: \(messageId)")
        
        // Skip if this is the same as last message
        if messageId == lastMessageId {
            Self.addLog("Duplicate message ignored: \(messageId)")
            return
        }
        
        // Save last message ID
        lastMessageId = messageId
        UserDefaults.standard.set(messageId, forKey: "pushedMessaging.lastMessageId")
        
        // Extract mfTraceId for confirmation (note: lowercase 'm' in received message)
        let mfTraceId = json["mfTraceId"] as? String ?? ""
        Self.addLog("Extracted mfTraceId: \(mfTraceId)")
        
        // Try to handle message with custom handler first
        var handled = false
        if let handler = onMessageReceived {
            handled = handler(messageString)
            Self.addLog("Custom message handler returned: \(handled)")
        }
        
        // If not handled, show as background notification
        if !handled {
            Self.addLog("Showing background notification for message: \(messageId)")
            showBackgroundNotification(json)
        }
        
        // Confirm WebSocket message
        confirmWebSocketMessage(messageId: messageId, mfTraceId: mfTraceId)
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
        
        // Stop keepalive mechanisms immediately
        stopKeepaliveTimer()
        stopHealthCheckTimer()
        
        Self.addLog("💀 WEBSOCKET УМЕР! Соединение потеряно")
        
        if status != .disconnected {
            status = .disconnected
            onStatusChange?(.disconnected)
        }
        
        if shouldReconnect {
            Self.addLog("🔄 Планируется переподключение после смерти WebSocket")
            scheduleReconnect()
        } else {
            Self.addLog("⚰️ WebSocket окончательно мертв - переподключение отключено")
        }
    }
    
    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        
        // Use different intervals based on app state
        let reconnectInterval: TimeInterval = isInBackground ? 30.0 : 5.0
        
        Self.addLog("Scheduling reconnect in \(reconnectInterval) seconds (background: \(isInBackground))")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: false) { [weak self] _ in
            if self?.shouldReconnect == true {
                if self?.isInBackground == true {
                    Self.addLog("Skipping reconnect while in background")
                    // Don't reconnect in background, wait for foreground
                    return
                }
                Self.addLog("Attempting WebSocket reconnect")
                self?.connect()
            }
        }
    }
    
    /// Manually check WebSocket connection state
    public func checkConnectionState() {
        guard let webSocketTask = webSocketTask else {
            Self.addLog("Connection check: No WebSocket task")
            if isConnected {
                handleConnectionLoss()
            }
            return
        }
        
        switch webSocketTask.state {
        case .running:
            if !isConnected {
                Self.addLog("Connection check: WebSocket running but not marked connected, fixing state")
                isConnected = true
                if status != .connected {
                    status = .connected
                    onStatusChange?(.connected)
                }
            }
        case .suspended:
            Self.addLog("Connection check: WebSocket suspended")
            if isConnected {
                handleConnectionLoss()
            }
        case .canceling:
            Self.addLog("Connection check: WebSocket canceling")
            if isConnected {
                handleConnectionLoss()
            }
        case .completed:
            Self.addLog("Connection check: WebSocket completed")
            if isConnected {
                handleConnectionLoss()
            }
        @unknown default:
            Self.addLog("Connection check: WebSocket in unknown state")
            if isConnected {
                handleConnectionLoss()
            }
        }
    }
    
    // MARK: - Message Confirmation
    
    /// Send confirmation for received WebSocket message
    private func confirmWebSocketMessage(messageId: String, mfTraceId: String) {
        Self.addLog("Preparing to confirm WebSocket message - ID: \(messageId), TraceID: \(mfTraceId)")
        
        let confirmationData: [String: Any] = [
            "messageId": messageId,
            "MfTraceId": mfTraceId
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: confirmationData),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            Self.addLog("Failed to create confirmation JSON for message: \(messageId)")
            return
        }
        
        Self.addLog("Sending WebSocket confirmation: \(jsonString)")
        sendMessage(jsonString)
    }
    
    /// Send message through WebSocket
    private func sendMessage(_ message: String) {
        guard isConnected, let webSocketTask = webSocketTask else {
            Self.addLog("Cannot send message: WebSocket not connected (isConnected: \(isConnected))")
            return
        }
        
        // Encode string to UTF-8 data (similar to Kotlin's encode(Charsets.UTF_8))
        guard let messageData = message.data(using: .utf8) else {
            Self.addLog("Failed to encode message to UTF-8 data")
            return
        }
        
        let wsMessage = URLSessionWebSocketTask.Message.data(messageData)
        webSocketTask.send(wsMessage) { error in
            if let error = error {
                Self.addLog("Failed to send WebSocket message: \(error.localizedDescription)")
            } else {
                Self.addLog("WebSocket confirmation sent successfully as UTF-8 data")
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
@available(iOS 13.0, *)
extension PushedWebSocketClient: URLSessionWebSocketDelegate {
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol `protocol`: String?) {
        Self.addLog("WebSocket connection opened with protocol: \(`protocol` ?? "none")")
        isConnected = true
        status = .connected
        onStatusChange?(.connected)
        reconnectTimer?.invalidate()
        
        // Reset keepalive state
        lastPongReceived = Date()
        pendingPingCount = 0
        
        // Start keepalive mechanisms only if not in background
        if !isInBackground {
            startKeepaliveTimer()
            startHealthCheckTimer()
            Self.addLog("Keepalive mechanisms started")
        } else {
            Self.addLog("WebSocket opened while in background - keepalive will start on foreground")
        }
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Причина неизвестна"
        Self.addLog("⚰️ WebSocket ЗАКРЫЛСЯ! Код: \(closeCode.rawValue), причина: \(reasonString)")
        
        // Stop keepalive mechanisms
        stopKeepaliveTimer()
        stopHealthCheckTimer()
        
        // Check if this was an expected closure or error
        switch closeCode {
        case .goingAway, .normalClosure:
            Self.addLog("✅ WebSocket закрылся нормально")
        default:
            Self.addLog("💀 WebSocket закрылся НЕОЖИДАННО!")
        }
        
        handleConnectionLoss()
    }
}

// MARK: - URLSessionDelegate
@available(iOS 13.0, *)
extension PushedWebSocketClient: URLSessionDelegate {
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            Self.addLog("💀 WebSocket ЗАВЕРШИЛСЯ С ОШИБКОЙ: \(error.localizedDescription)")
            
            // Stop keepalive mechanisms on error
            stopKeepaliveTimer()
            stopHealthCheckTimer()
            
            // Check if error is network-related (common during background transitions)
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet,
                     NSURLErrorNetworkConnectionLost,
                     NSURLErrorTimedOut:
                    Self.addLog("🌐 СЕТЕВАЯ ОШИБКА: \(nsError.localizedDescription)")
                default:
                    Self.addLog("🔗 URL ОШИБКА: \(nsError.localizedDescription)")
                }
            }
            
            handleConnectionLoss()
        } else {
            Self.addLog("✅ WebSocket завершился успешно")
        }
    }
    
    public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error = error {
            Self.addLog("💀 URLSession СТАЛА НЕДЕЙСТВИТЕЛЬНОЙ С ОШИБКОЙ: \(error.localizedDescription)")
        } else {
            Self.addLog("⚠️ URLSession стала недействительной")
        }
        
        // Stop keepalive mechanisms
        stopKeepaliveTimer()
        stopHealthCheckTimer()
        
        handleConnectionLoss()
    }
}