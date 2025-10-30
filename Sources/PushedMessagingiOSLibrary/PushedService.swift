import Foundation
import UIKit
import BackgroundTasks
import Starscream
import UserNotifications

// Bridge nested enum for use in this file while keeping it inside its class
public typealias PushedServiceStatus = PushedMessaging.PushedServiceStatus

/// Service responsible for managing WebSocket connections and real-time messaging
@available(iOS 13.0, *)
public class PushedService {
    
    // MARK: - Properties
    
    private var webSocketClient: WebSocketClient?
    private let addLog: (String) -> Void
    
    // Store notification observer tokens for proper cleanup
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    
    // Background task management
    private var extraBgTask: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Callbacks
    
    /// WebSocket status change callback
    public var onStatusChange: ((PushedServiceStatus) -> Void)?
    
    /// WebSocket message received callback - return true if message was handled
    public var onMessageReceived: ((String) -> Bool)?
    
    /// Callback to get client token
    var getClientToken: (() -> String?)?
    
    // MARK: - Computed Properties
    
    /// Return WebSocket connection status
    public var status: PushedServiceStatus {
        return webSocketClient?.status ?? .disconnected
    }
    
    /// Check if WebSocket is enabled
    public var isEnabled: Bool {
        return UserDefaults.standard.bool(forKey: "pushedMessaging.webSocketEnabled")
    }
    
    // MARK: - Initialization
    
    init(logger: @escaping (String) -> Void) {
        self.addLog = logger
        setupApplicationStateObservers()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Public Methods
    
    /// Enable WebSocket connection (will auto-start when token is available)
    public func enable() {
        addLog("WebSocket enabled")
        UserDefaults.standard.set(true, forKey: "pushedMessaging.webSocketEnabled")
        if let token = getClientToken?() {
            startConnection(with: token)
        }
    }
    
    /// Disable WebSocket connection
    public func disable() {
        addLog("WebSocket disabled")
        UserDefaults.standard.set(false, forKey: "pushedMessaging.webSocketEnabled")
        stopConnection()
    }
    
    /// Start WebSocket connection with token
    public func startConnection(with token: String) {
        guard isEnabled else {
            addLog("Cannot start WebSocket: Service is disabled")
            return
        }
        
        if webSocketClient != nil {
            addLog("WebSocket client already exists, stopping previous connection")
            stopConnection()
        }
        
        addLog("Starting WebSocket connection")
        webSocketClient = WebSocketClient(token: token, logger: addLog)
        
        webSocketClient?.onStatusChange = { [weak self] status in
            self?.addLog("WebSocket status changed to: \(status.rawValue)")
            self?.onStatusChange?(status)
        }
        
        webSocketClient?.onMessageReceived = { [weak self] message in
            self?.addLog("WebSocket message received via handler")
            return self?.onMessageReceived?(message) ?? false
        }
        
        webSocketClient?.connect()
    }
    
    /// Stop WebSocket connection
    public func stopConnection() {
        addLog("Stopping WebSocket connection")
        webSocketClient?.disconnect()
        webSocketClient = nil
    }
    
    /// Restart WebSocket connection
    public func restartConnection() {
        addLog("Restarting WebSocket connection")
        if let token = getClientToken?() {
            stopConnection()
            startConnection(with: token)
        }
    }
    
    /// Manually check WebSocket connection health
    public func checkConnectionHealth() {
        addLog("Checking WebSocket connection health")
        webSocketClient?.checkConnectionState()
    }
    
    /// Get detailed WebSocket diagnostics
    public func getDiagnostics() -> String {
        var diagnostics = "=== WebSocket Diagnostics ===\n"
        diagnostics += "Timestamp: \(Date())\n"
        diagnostics += "WebSocket Enabled: \(isEnabled)\n"
        diagnostics += "Client Token Available: \(getClientToken?() != nil)\n"
        diagnostics += "Status: \(status.rawValue)\n"
        
        if webSocketClient != nil {
            diagnostics += "Client Instance: Available\n"
        } else {
            diagnostics += "Client Instance: Nil\n"
        }
        
        diagnostics += "iOS Version: \(UIDevice.current.systemVersion)\n"
        diagnostics += "App State: \(UIApplication.shared.applicationState.rawValue)\n"
        
        return diagnostics
    }
    
    // MARK: - Application State Management
    
    /// Setup observers for application state changes
    private func setupApplicationStateObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.addLog("Application entered background - managing WebSocket connection")
            self?.handleAppDidEnterBackground()
        }
        
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.addLog("Application will enter foreground - restoring WebSocket connection")
            self?.handleAppWillEnterForeground()
        }
        
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.addLog("Application became active - ensuring WebSocket connection")
            self?.handleAppDidBecomeActive()
        }
        
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.addLog("Application will resign active - preparing WebSocket for background")
            self?.handleAppWillResignActive()
        }
    }
    
    /// Handle application entering background
    private func handleAppDidEnterBackground() {
        if isEnabled {
            let isAPNSEnabled = PushedMessaging.isAPNSEnabled
            if !isAPNSEnabled {
                addLog("APNs disabled - keeping WebSocket alive as long as possible in background")
            } else {
                addLog("APNs enabled - keeping WebSocket alive during extra background time")
            }
        }
        
        // Also schedule a BGProcessingTask to let iOS wake us for network work
        PushedMessaging.enableBackgroundWebSocketTasks()

        // Request ~30s extra execution so socket can stay alive a bit longer
        // This is especially important when APNs is disabled
        startShortBackgroundExecution()
    }
    
    /// Handle application entering foreground
    private func handleAppWillEnterForeground() {
        if isEnabled && getClientToken?() != nil {
            // Restore WebSocket connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if let client = self?.webSocketClient {
                    client.restoreFromBackground()
                    self?.addLog("WebSocket restored from background")
                } else {
                    // WebSocket was completely lost, restart it
                    if let token = self?.getClientToken?() {
                        self?.startConnection(with: token)
                        self?.addLog("WebSocket restarted after background")
                    }
                }
            }
        }
        
        // Foreground: optional – cancel scheduled background tasks
        PushedMessaging.disableBackgroundWebSocketTasks()

        // We're back to foreground — end the short background task if active
        endShortBackgroundExecution()
    }
    
    /// Handle application becoming active
    private func handleAppDidBecomeActive() {
        if isEnabled && getClientToken?() != nil {
            // Ensure WebSocket is running when app becomes fully active
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if self?.webSocketClient?.status != .connected {
                    self?.addLog("WebSocket not connected when app became active, restarting")
                    self?.restartConnection()
                }
            }
        }
    }
    
    /// Handle application resigning active
    private func handleAppWillResignActive() {
        // App is about to become inactive (could be going to background or being interrupted)
        addLog("Application will resign active")
    }
    
    // MARK: - Background Execution
    
    /// Request additional background time (≈30s) so WebSocket can keep
    /// receiving messages shortly after user backgrounds the app.
    private func startShortBackgroundExecution() {
        guard extraBgTask == .invalid else { return }
        
        extraBgTask = UIApplication.shared.beginBackgroundTask(withName: "PushedWS") { [weak self] in
            // Expiration handler — iOS is about to suspend us; clean up.
            let isAPNSEnabled = PushedMessaging.isAPNSEnabled
            if isAPNSEnabled {
                self?.addLog("Background task expired - stopping WebSocket (APNs will handle notifications)")
            } else {
                self?.addLog("Background task expired - forced to stop WebSocket (no APNs fallback available)")
            }
            self?.stopConnection()
            self?.endShortBackgroundExecution()
        }
        
        if extraBgTask != .invalid {
            addLog("Obtained ~30s of additional background time for WebSocket")
        } else {
            addLog("Failed to obtain extra background time (beginBackgroundTask returned invalid identifier)")
        }
    }
    
    /// End previously requested background time.
    private func endShortBackgroundExecution() {
        guard extraBgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(extraBgTask)
        addLog("Ended short background execution")
        extraBgTask = .invalid
    }
    
    // MARK: - Cleanup
    
    /// Clean up resources and observers
    private func cleanup() {
        addLog("Cleaning up PushedService resources")
        
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
        stopConnection()
    }
}

// MARK: - WebSocket Client

@available(iOS 13.0, *)
private extension PushedService {
    
    /// Internal WebSocket client implementation
    class WebSocketClient: NSObject, WebSocketDelegate {
        
        private var socket: WebSocket?
        private var token: String
        private var lastMessageId: String?
        private let addLog: (String) -> Void
        
        var status: PushedServiceStatus = .disconnected {
            didSet {
                if oldValue != status {
                    onStatusChange?(status)
                    addWSLog("Status changed to: \(status.rawValue)")
                }
            }
        }
        
        var onStatusChange: ((PushedServiceStatus) -> Void)?
        var onMessageReceived: ((String) -> Bool)?
        
        private func addWSLog(_ event: String) {
            let logMessage = "WebSocket (Starscream): \(event)"
            print("⭐️ \(logMessage)")
            if UserDefaults.standard.bool(forKey: "pushedMessaging.loggerEnabled") {
                let log = UserDefaults.standard.string(forKey: "pushedMessaging.pushedLog") ?? ""
                UserDefaults.standard.set(log + "\(Date()): \(logMessage)\n", forKey: "pushedMessaging.pushedLog")
            }
        }
        
        init(token: String, logger: @escaping (String) -> Void) {
            self.token = token
            self.addLog = logger
            self.lastMessageId = UserDefaults.standard.string(forKey: "pushedMessaging.lastMessageId")
            super.init()
            setupWebSocket()
        }
        
        deinit {
            addWSLog("Deinitializing")
            socket?.disconnect()
        }
        
        private func setupWebSocket() {
            guard let url = URL(string: "wss://sub.pushed.dev/v3/open-websocket") else {
                addWSLog("Invalid WebSocket URL")
                return
            }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            
            socket = WebSocket(request: request)
            socket?.delegate = self
            // Starscream handles ping/pong and keep-alive automatically.
        }
        
        // MARK: - Public Control Methods
        
        func connect() {
            addWSLog("Connecting...")
            status = .connecting
            socket?.connect()
        }
        
        func disconnect() {
            addWSLog("Disconnecting...")
            socket?.disconnect()
        }
        
        func prepareForBackground() {
            let isAPNSEnabled = PushedMessaging.isAPNSEnabled
            if isAPNSEnabled {
                addWSLog("Preparing for background - disconnecting (APNs will handle notifications).")
                socket?.disconnect()
            } else {
                addWSLog("Preparing for background - keeping connection alive (APNs disabled).")
                // Don't disconnect - keep WebSocket alive to receive notifications
            }
        }
        
        func restoreFromBackground() {
            addWSLog("Restoring from background - reconnecting.")
            socket?.connect()
        }
        
        func checkConnectionState() {
            addWSLog("Connection state check: isConnected = \(status == .connected)")
        }
        
        // MARK: - WebSocketDelegate
        
        func didReceive(event: WebSocketEvent, client: Starscream.WebSocketClient) {
            switch event {
            case .connected(let headers):
                status = .connected
                addWSLog("Connected with headers: \(headers)")
            case .disconnected(let reason, let code):
                status = .disconnected
                addWSLog("Disconnected. Reason: \(reason), Code: \(code)")
            case .text(let string):
                handleTextMessage(string)
            case .binary(let data):
                addWSLog("Received binary data: \(data.count) bytes")
                if let text = String(data: data, encoding: .utf8) {
                    handleTextMessage(text)
                }
            case .ping, .pong:
                // Starscream handles this automatically, but we can log if needed.
                break
            case .viabilityChanged(let isViable):
                addWSLog("Connection viability changed: \(isViable)")
                if !isViable {
                    status = .connecting // Or .disconnected
                }
            case .reconnectSuggested(let shouldReconnect):
                addWSLog("Reconnect suggested: \(shouldReconnect)")
                if shouldReconnect {
                    socket?.connect()
                }
            case .cancelled:
                status = .disconnected
                addWSLog("Cancelled")
            case .error(let error):
                status = .disconnected
                addWSLog("Error: \(error?.localizedDescription ?? "Unknown error")")
            case .peerClosed:
                status = .disconnected
                addWSLog("Connection closed by peer.")
            }
        }
        
        private func handleTextMessage(_ messageString: String) {
            addWSLog("Received message: \(messageString)")
            
            guard let data = messageString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                addWSLog("Message is not valid JSON.")
                return
            }
            
            guard let messageId = json["messageId"] as? String else {
                addWSLog("Message without messageId received.")
                return
            }
            
            // Deduplication against previously received APNs notifications
            if PushedMessaging.isMessageProcessed(messageId) {
                addWSLog("Duplicate message already processed via APNs. Ignoring WebSocket push (messageId: \(messageId))")
                return
            }
            
            if messageId == lastMessageId {
                addWSLog("Duplicate message ignored: \(messageId)")
                return
            }
            
            let mfTraceId = json["mfTraceId"] as? String ?? ""
            let handled = onMessageReceived?(messageString) ?? false
            
            if handled {
                addWSLog("Message handled by custom handler.")
                PushedMessaging.markMessageProcessed(messageId)
                confirmWebSocketMessage(messageId: messageId, mfTraceId: mfTraceId)
                lastMessageId = messageId
                UserDefaults.standard.set(messageId, forKey: "pushedMessaging.lastMessageId")
            } else {
                // Check if we should show notification based on app state and APNs status
                let isAPNSEnabled = PushedMessaging.isAPNSEnabled
                let shouldShowNotification = UIApplication.shared.applicationState != .background || !isAPNSEnabled
                
                if shouldShowNotification {
                    if UIApplication.shared.applicationState != .background {
                        addWSLog("App is active, showing local notification for message: \(messageId)")
                    } else {
                        addWSLog("App is in background but APNs is disabled, showing WebSocket notification for message: \(messageId)")
                    }
                    PushedMessaging.markMessageProcessed(messageId)
                    showBackgroundNotification(json, identifier: messageId)
                    confirmWebSocketMessage(messageId: messageId, mfTraceId: mfTraceId)
                    lastMessageId = messageId
                    UserDefaults.standard.set(messageId, forKey: "pushedMessaging.lastMessageId")
                } else {
                    addWSLog("App is in background and APNs is enabled, suppressing notification from WebSocket. Waiting for APNs.")
                }
            }
        }
        
        private func confirmWebSocketMessage(messageId: String, mfTraceId: String) {
            var confirmationDict: [String: Any] = ["messageId": messageId]
            if !mfTraceId.isEmpty {
                confirmationDict["mfTraceId"] = mfTraceId
            }
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: confirmationDict) else {
                addWSLog("Failed to create confirmation JSON.")
                return
            }
            
            socket?.write(data: jsonData) {
                self.addWSLog("Confirmation sent for messageId: \(messageId)")
            }
        }
        
        private func showBackgroundNotification(_ messageData: [String: Any], identifier: String) {
            DispatchQueue.main.async {
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    guard settings.authorizationStatus == .authorized else {
                        self.addWSLog("Notification permissions not granted, cannot show notification.")
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
                            self.addWSLog("Failed to schedule notification: \(error.localizedDescription)")
                        } else {
                            self.addWSLog("Background notification scheduled successfully.")
                            // Send "Show" interaction to server since notification is displayed
                            PushedMessaging.confirmMessageAction(identifier, action: "Show")
                        }
                    }
                }
            }
        }
    }
}
