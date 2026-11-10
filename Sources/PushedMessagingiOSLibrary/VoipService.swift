import Foundation
import PushKit
import CallKit

/// Incoming call delivered through Pushed.
public struct PushedCall {
    /// Sender-provided call identifier. Pass it to `PushedMessaging.reportCallEnded(_:)`.
    public let callId: String
    /// Text shown on the system call screen.
    public let displayName: String
    /// Sender payload, forwarded verbatim.
    public let payload: [String: Any]
}

/// PushKit + CallKit integration.
///
/// iOS kills the process if a voip push is not reported to CallKit before the delivery
/// completion handler runs, so reporting happens here and cannot be left to the app.
class VoipService: NSObject {

    private let addLog: (String) -> Void
    private var registry: PKPushRegistry?
    private var provider: CXProvider?

    private(set) var lastVoipToken: String?
    private(set) var isEnabled = false

    /// CallKit only hands back a UUID, so the messageId needed for interaction reporting
    /// is kept here. `answered` distinguishes a declined call from a normal hangup —
    /// CXEndCallAction fires for both.
    private struct CallRecord {
        let call: PushedCall
        let messageId: String?
        var answered: Bool
    }

    private var uuidByCallId: [String: UUID] = [:]
    private var recordByUuid: [UUID: CallRecord] = [:]
    private let lock = NSLock()

    var onTokenReceived: ((String) -> Void)?
    var onIncomingCall: ((PushedCall) -> Void)?
    var onCallAnswered: ((PushedCall) -> Void)?
    var onCallDeclined: ((PushedCall) -> Void)?
    /// messageId of a delivered voip push, for delivery confirmation
    var onMessageDelivered: ((String) -> Void)?
    /// (messageId, ClientInteraction) — "Show" when the call screen appears,
    /// "Click" on answer, "Close" on decline. Mirrors what a regular push reports.
    var onInteraction: ((String, String) -> Void)?

    init(logger: @escaping (String) -> Void) {
        self.addLog = logger
        super.init()
    }

    // MARK: - Lifecycle

    /// Registers for voip pushes. `callerName` is the app name shown by CallKit.
    func enable(callerName: String) {
        guard !isEnabled else {
            addLog("[VoIP] Already enabled")
            return
        }
        isEnabled = true

        let configuration: CXProviderConfiguration
        if #available(iOS 14.0, *) {
            configuration = CXProviderConfiguration()
        } else {
            configuration = CXProviderConfiguration(localizedName: callerName)
        }
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]

        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: nil)
        self.provider = provider

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry

        addLog("[VoIP] Registered for voip pushes")

        // A token issued in a previous launch is handed back immediately, but iOS does not
        // always call the delegate again — read it so the first launch after enabling works.
        if let existing = registry.pushToken(for: .voIP)?.hexString, !existing.isEmpty {
            handleToken(existing, source: "cached")
        }
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        registry?.desiredPushTypes = []
        registry = nil
        provider?.invalidate()
        provider = nil
        lastVoipToken = nil
        addLog("[VoIP] Disabled")
    }

    /// Dismisses the system call screen — remote hangup, SIP failure, or app-side cancel.
    func reportCallEnded(_ callId: String, reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = uuid(for: callId) else {
            addLog("[VoIP] reportCallEnded: unknown callId \(callId)")
            return
        }
        provider?.reportCall(with: uuid, endedAt: nil, reason: reason)
        forget(uuid)
        addLog("[VoIP] Call ended: \(callId) (\(reason.rawValue))")
    }

    // MARK: - Call registry

    private func remember(_ call: PushedCall, messageId: String?) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let existing = uuidByCallId[call.callId] {
            return existing
        }
        // CallKit needs a UUID; reuse the sender's callId when it already is one.
        let uuid = UUID(uuidString: call.callId) ?? UUID()
        uuidByCallId[call.callId] = uuid
        recordByUuid[uuid] = CallRecord(call: call, messageId: messageId, answered: false)
        return uuid
    }

    private func record(for uuid: UUID) -> CallRecord? {
        lock.lock()
        defer { lock.unlock() }
        return recordByUuid[uuid]
    }

    private func markAnswered(_ uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        recordByUuid[uuid]?.answered = true
    }

    private func uuid(for callId: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return uuidByCallId[callId]
    }

    private func forget(_ uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let record = recordByUuid.removeValue(forKey: uuid) {
            uuidByCallId.removeValue(forKey: record.call.callId)
        }
    }

    // MARK: - Payload

    private func handleToken(_ token: String, source: String) {
        guard token != lastVoipToken else { return }
        lastVoipToken = token
        addLog("[VoIP] Token (\(source)): \(token.prefix(8))… len=\(token.count)")
        onTokenReceived?(token)
    }

    /// Pushed packs application data into a `data` JSON string, so flatten it into the payload.
    static func parseCall(from dictionary: [AnyHashable: Any]) -> PushedCall {
        var payload: [String: Any] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String, key != "aps" else { continue }
            payload[key] = value
        }

        if let dataString = payload["data"] as? String,
           let data = dataString.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let parsed = object as? [String: Any] {
            payload.merge(parsed) { _, new in new }
        }

        let callId = (payload["callId"] as? String)
            ?? (payload["call_id"] as? String)
            ?? (payload["messageId"] as? String)
            ?? UUID().uuidString

        var displayName = (payload["displayName"] as? String) ?? ""
        if displayName.isEmpty, let notification = dictionary["pushedNotification"] as? [AnyHashable: Any] {
            displayName = (notification["Title"] as? String) ?? ""
        }
        if displayName.isEmpty {
            displayName = "Входящий вызов"
        }

        return PushedCall(callId: callId, displayName: displayName, payload: payload)
    }
}

// MARK: - PKPushRegistryDelegate

extension VoipService: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        handleToken(pushCredentials.token.hexString, source: "didUpdate")
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        addLog("[VoIP] Token invalidated")
        lastVoipToken = nil
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }

        addLog("[VoIP] Incoming push: \(payload.dictionaryPayload)")
        let call = Self.parseCall(from: payload.dictionaryPayload)
        let messageId = call.payload["messageId"] as? String
        let uuid = remember(call, messageId: messageId)

        if let messageId = messageId {
            onMessageDelivered?(messageId)
        }

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: call.callId)
        update.localizedCallerName = call.displayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        // reportNewIncomingCall must happen before completion(), otherwise iOS terminates
        // the app and eventually stops delivering voip pushes altogether.
        provider?.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error = error {
                self?.addLog("[VoIP] reportNewIncomingCall failed: \(error.localizedDescription)")
                self?.forget(uuid)
            } else {
                self?.addLog("[VoIP] Call screen shown: \(call.callId)")
                // Same reporting a regular push does once its banner is on screen
                if let messageId = messageId {
                    self?.onInteraction?(messageId, "Show")
                }
                self?.onIncomingCall?(call)
            }
            completion()
        }
    }
}

// MARK: - CXProviderDelegate

extension VoipService: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        addLog("[VoIP] Provider reset")
        lock.lock()
        uuidByCallId.removeAll()
        recordByUuid.removeAll()
        lock.unlock()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let record = record(for: action.callUUID) {
            addLog("[VoIP] Answered: \(record.call.callId)")
            markAnswered(action.callUUID)
            // Green button is the call-screen equivalent of tapping a notification
            if let messageId = record.messageId {
                onInteraction?(messageId, "Click")
            }
            onCallAnswered?(record.call)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let record = record(for: action.callUUID) {
            if record.answered {
                // Hangup after a normal conversation — not a rejection, nothing to report
                addLog("[VoIP] Ended after answer: \(record.call.callId)")
            } else {
                addLog("[VoIP] Declined: \(record.call.callId)")
                if let messageId = record.messageId {
                    onInteraction?(messageId, "Close")
                }
                onCallDeclined?(record.call)
            }
        }
        forget(action.callUUID)
        action.fulfill()
    }
}
