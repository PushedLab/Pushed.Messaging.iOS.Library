import Foundation
import Starscream
import UserNotifications

@available(iOS 13.0, *)
public class PushedWebSocketClient: NSObject, WebSocketDelegate {
    
    private var socket: WebSocket?
    private var token: String
    private var lastMessageId: String?
    
    public private(set) var status: PushedServiceStatus = .disconnected {
        didSet {
            if oldValue != status {
                onStatusChange?(status)
                Self.addLog("Status changed to: \(status.rawValue)")
            }
        }
    }
    
    public var onStatusChange: ((PushedServiceStatus) -> Void)?
    public var onMessageReceived: ((String) -> Bool)?
    
    private static func addLog(_ event: String) {
        let logMessage = "WebSocket (Starscream): \(event)"
        print("⭐️ \(logMessage)")
        if UserDefaults.standard.bool(forKey: "pushedMessaging.loggerEnabled") {
            let log = UserDefaults.standard.string(forKey: "pushedMessaging.pushedLog") ?? ""
            UserDefaults.standard.set(log + "\(Date()): \(logMessage)\n", forKey: "pushedMessaging.pushedLog")
        }
    }
    
    public init(token: String) {
        self.token = token
        self.lastMessageId = UserDefaults.standard.string(forKey: "pushedMessaging.lastMessageId")
        super.init()
        setupWebSocket()
    }
    
    deinit {
        Self.addLog("Deinitializing")
        socket?.disconnect()
    }
    
    private func setupWebSocket() {
        guard let url = URL(string: "wss://sub.multipushed.ru/v2/open-websocket/\(token)") else {
            Self.addLog("Invalid WebSocket URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        socket = WebSocket(request: request)
        socket?.delegate = self
        // Starscream handles ping/pong and keep-alive automatically.
    }
    
    // MARK: - Public Control Methods
    
    public func connect() {
        Self.addLog("Connecting...")
        status = .connecting
        socket?.connect()
    }
    
    public func disconnect() {
        Self.addLog("Disconnecting...")
        socket?.disconnect()
    }

    public func prepareForBackground() {
        Self.addLog("Preparing for background - disconnecting.")
        socket?.disconnect()
    }

    public func restoreFromBackground() {
        Self.addLog("Restoring from background - reconnecting.")
        socket?.connect()
    }

    public func checkConnectionState() {
        Self.addLog("Connection state check: isConnected = \(status == .connected)")
    }
    
    // MARK: - WebSocketDelegate
    
    public func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .connected(let headers):
            status = .connected
            Self.addLog("Connected with headers: \(headers)")
        case .disconnected(let reason, let code):
            status = .disconnected
            Self.addLog("Disconnected. Reason: \(reason), Code: \(code)")
        case .text(let string):
            handleTextMessage(string)
        case .binary(let data):
            Self.addLog("Received binary data: \(data.count) bytes")
            if let text = String(data: data, encoding: .utf8) {
                handleTextMessage(text)
            }
        case .ping, .pong:
            // Starscream handles this automatically, but we can log if needed.
            break
        case .viabilityChanged(let isViable):
            Self.addLog("Connection viability changed: \(isViable)")
            if !isViable {
                status = .connecting // Or .disconnected
            }
        case .reconnectSuggested(let shouldReconnect):
            Self.addLog("Reconnect suggested: \(shouldReconnect)")
            if shouldReconnect {
                socket?.connect()
            }
        case .cancelled:
            status = .disconnected
            Self.addLog("Cancelled")
        case .error(let error):
            status = .disconnected
            Self.addLog("Error: \(error?.localizedDescription ?? "Unknown error")")
        case .peerClosed:
            status = .disconnected
            Self.addLog("Connection closed by peer.")
        }
    }
    
    private func handleTextMessage(_ messageString: String) {
        Self.addLog("Received message: \(messageString)")
        
        guard let data = messageString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.addLog("Message is not valid JSON.")
            return
        }
        
        guard let messageId = json["messageId"] as? String else {
            Self.addLog("Message without messageId received.")
            return
        }
        
        // Deduplication against previously received APNs notifications
        if PushedMessagingiOSLibrary.isMessageProcessed(messageId) {
            Self.addLog("Duplicate message already processed via APNs. Ignoring WebSocket push (messageId: \(messageId))")
            return
        }
        
        // Mark as processed so APNs duplicate won't be shown later
        PushedMessagingiOSLibrary.markMessageProcessed(messageId)
        Self.addLog("[Dedup] messageId \(messageId) marked as processed from WebSocket path")
        
        if messageId == lastMessageId {
            Self.addLog("Duplicate message ignored: \(messageId)")
            return
        }
        
        lastMessageId = messageId
        UserDefaults.standard.set(messageId, forKey: "pushedMessaging.lastMessageId")
        
        let mfTraceId = json["mfTraceId"] as? String ?? ""
        
        let handled = onMessageReceived?(messageString) ?? false
        
        if handled {
            Self.addLog("Message handled by custom handler.")
        } else {
            Self.addLog("Showing background notification for message: \(messageId)")
            showBackgroundNotification(json, identifier: messageId)
        }
        
        confirmWebSocketMessage(messageId: messageId, mfTraceId: mfTraceId)
    }
    
    private func confirmWebSocketMessage(messageId: String, mfTraceId: String) {
        var confirmationDict: [String: Any] = ["messageId": messageId]
        if !mfTraceId.isEmpty {
            confirmationDict["mfTraceId"] = mfTraceId
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: confirmationDict) else {
            Self.addLog("Failed to create confirmation JSON.")
            return
        }
        
        socket?.write(data: jsonData) {
            Self.addLog("Confirmation sent for messageId: \(messageId)")
        }
    }

    private func showBackgroundNotification(_ messageData: [String: Any], identifier: String) {
        DispatchQueue.main.async {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .authorized else {
                    Self.addLog("Notification permissions not granted, cannot show notification.")
                    return
                }
                
                let content = UNMutableNotificationContent()
                
                if let pushedNotification = messageData["pushedNotification"] as? [String: Any] {
                    content.title = pushedNotification["Title"] as? String ?? "New Message"
                    content.body = pushedNotification["Body"] as? String ?? "You have a new message."
                    content.sound = .default
                    if let soundName = pushedNotification["Sound"] as? String, !soundName.isEmpty {
                        content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
                    }
                } else {
                    content.title = "New Message"
                    // Use plain data string as body if available
                    if let bodyString = messageData["data"] as? String, !bodyString.isEmpty {
                        content.body = bodyString
                    } else {
                        content.body = "You have a new message via WebSocket."
                    }
                    content.sound = .default
                }
                
                content.userInfo = messageData
                
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        Self.addLog("Failed to schedule notification: \(error.localizedDescription)")
                    } else {
                        Self.addLog("Background notification scheduled successfully.")
                    }
                }
            }
        }
    }
}