import AppKit
import Foundation
import Combine
import PingCore

/// All mutable state and application callbacks are confined to the main thread.
final class RelayClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    enum State { case idle, connecting, connected, reconnecting, failed }
    @Published var serverAddress: String {
        didSet { defaults?.set(serverAddress, forKey: "relayServer") }
    }
    @Published var displayName: String {
        didSet { defaults?.set(displayName, forKey: "relayName") }
    }
    @Published var roomInput = ""
    @Published var receiveEnabled: Bool {
        didSet { defaults?.set(receiveEnabled, forKey: "relayReceive") }
    }
    @Published var muteTeammates: Bool {
        didSet { defaults?.set(muteTeammates, forKey: "relayMuteTeammates") }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var status = "填写服务器地址，创建房间或加入朋友的房间。"
    @Published private(set) var room = ""
    @Published private(set) var peers: [RelayPeer] = []
    @Published private(set) var memberID = ""
    var onPing: ((PingKind, String) -> Void)?
    var onEmote: ((EmotePayload, String) -> Void)?
    var onPositionedPing: ((PingKind, String, CGPoint) -> Void)?
    var onPositionedEmote: ((EmotePayload, String, CGPoint) -> Void)?
    @Published private(set) var positionWarning: String?
    private var supportsEmotes = false
    private var nextEmote = Date.distantPast
    var onConnected: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onTransportError: ((Error) -> Void)?
    var isActive: Bool { wanted }
    var canSend: Bool { state == .connected && peers.count > 1 }
    var formattedRoom: String {
        stride(from: 0, to: room.count, by: 4).map { offset in
            let start = room.index(room.startIndex, offsetBy: offset)
            let end = room.index(start, offsetBy: min(4, room.count-offset))
            return String(room[start..<end])
        }.joined(separator: "-")
    }
    private let defaults: UserDefaults?
    private let resumeStore: RelaySessionStore
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var pinnedSocket: PinnedRelaySocket?
    private var endpoint: URL?
    private var wanted = false
    private var action = "create"
    private var token: String?
    private var generation = 0
    private var retryCount = 0
    private var reconnectWork: DispatchWorkItem?
    private var handshakeTimer: Timer?
    private var heartbeatTimer: Timer?
    private var recentIDs: [String] = []
    private var nextSend = Date.distantPast

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        resumeStore = RelaySessionStore(defaults: defaults)
        let savedAddress = defaults?.string(forKey: "relayServer") ?? ""
        serverAddress = savedAddress.isEmpty ? (RelayServerTrust.endpoint ?? "") : savedAddress
        displayName = defaults?.string(forKey: "relayName") ?? "朋友"
        receiveEnabled = defaults?.object(forKey: "relayReceive") == nil ? true : defaults!.bool(forKey: "relayReceive")
        muteTeammates = defaults?.bool(forKey: "relayMuteTeammates") ?? false
        super.init()
    }
    func createRoom() { connect(action: "create") }
    func joinRoom() { connect(action: "join") }
    func pasteRoomCode(from pasteboard: NSPasteboard = .general) {
        guard let text = pasteboard.string(forType: .string),
              RelayProtocol.validRoomCode(RelayProtocol.roomCode(text)) else {
            status = "剪贴板中没有有效的 12 位房间码。"
            return
        }
        roomInput = RelayProtocol.roomCode(text)
        status = isActive ? "房间码已粘贴，点击切换房间后生效。" : "房间码已粘贴，点击加入房间。"
    }
    private func connect(action: String) {
        guard let url = RelayProtocol.endpoint(serverAddress) else {
            inputError("请输入 wss://域名/ws；本机测试可用 ws://127.0.0.1:8787/ws。")
            return
        }
        let code = RelayProtocol.roomCode(roomInput)
        if action == "join" && !RelayProtocol.validRoomCode(code) {
            inputError("请输入朋友分享的 12 位房间码。")
            return
        }
        disconnect()
        displayName = RelayProtocol.displayName(displayName)
        self.action = action; endpoint = url; wanted = true
        room = action == "join" ? code : ""
        retryCount = 0; recentIDs.removeAll(); nextSend = .distantPast
        open()
    }
    private func inputError(_ message: String) {
        if isActive { status = message }
        else { terminal(message) }
    }
    /// App quit/update only closes transport. The server reserves this identity
    /// and the next launch resumes using the same credential and room code.
    func suspend() {
        wanted = false; reconnectWork?.cancel(); reconnectWork = nil
        closeTransport(); peers = []; state = .idle; status = "房间已保存，下次启动自动恢复。"
    }
    @discardableResult func restoreSavedSession() -> Bool {
        guard !wanted, let url = RelayProtocol.endpoint(serverAddress), let saved = resumeStore.load(url) else { return false }
        closeTransport(); endpoint = url; room = saved.room; token = saved.token; memberID = saved.memberID
        roomInput = formattedRoom; action = "resume"; wanted = true; retryCount = 0; recentIDs = []; open()
        return true
    }
    func disconnect() {
        if let endpoint { resumeStore.remove(endpoint) }
        if let configured = RelayProtocol.endpoint(serverAddress), configured != endpoint { resumeStore.remove(configured) }
        wanted = false; reconnectWork?.cancel(); reconnectWork = nil
        closeTransport(leaving: true)
        token = nil; room = ""; memberID = ""; peers = []
        state = .idle; status = "联动已断开。"
    }
    func sendPing(_ kind: PingKind, position: CGPoint) {
        guard RelayPosition(position).isValid else { return }
        guard canSend, Date() >= nextSend else { return }
        nextSend = Date().addingTimeInterval(0.15)
        var packet = RelayMessage(type: "ping")
        packet.eventID = UUID().uuidString; packet.kind = kind
        packet.position = RelayPosition(position)
        send(packet, generation: generation)
    }
    func sendEmote(_ emote: EmotePayload, position: CGPoint) {
        guard RelayPosition(position).isValid else { return }
        guard canSend, emote.isValid, Date() >= nextEmote else { return }
        guard supportsEmotes else { status = "服务器需要更新后才能传送表情。"; return }
        nextEmote = Date().addingTimeInterval(1)
        var packet = RelayMessage(type: "emote"); packet.eventID = UUID().uuidString; packet.emote = emote
        packet.position = RelayPosition(position)
        send(packet, generation: generation)
    }
    func reconnectAfterWake() {
        guard wanted else { return }
        transportFailed(generation: generation)
    }
    private func open() {
        guard wanted, let endpoint else { return }
        closeTransport()
        state = retryCount == 0 ? .connecting : .reconnecting
        status = retryCount == 0 ? "正在连接服务器…" : "连接中断，正在重新连接…"
        let current = generation
        if let host = endpoint.host, let port = endpoint.port, RelayServerTrust.matches(host: host, port: port) {
            guard let transport = PinnedRelaySocket(endpoint: endpoint) else {
                terminal("服务器证书配置缺失或不正确，请重新安装对应版本。"); return
            }
            pinnedSocket = transport
            transport.onOpen = { [weak self] in self?.sendHello(generation: current) }
            transport.onMessage = { [weak self] data in
                guard let self, self.wanted, self.generation == current else { return }
                guard let packet = try? JSONDecoder().decode(RelayMessage.self, from: data) else {
                    self.terminal("服务器消息格式不正确，请检查中继版本。"); return
                }
                self.handle(packet)
            }
            transport.onFailure = { [weak self] error in
                guard let self, self.generation == current else { return }
                self.onTransportError?(error); self.transportFailed(generation: current)
            }
            transport.start()
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            config.timeoutIntervalForRequest = 12
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session!.webSocketTask(with: endpoint)
            task.maximumMessageSize = RelayProtocol.maxMessageBytes; socket = task
            task.resume()
            receive(task, generation: current)
            sendHello(generation: current)
        }
        let timer = Timer(timeInterval: 12, repeats: false) { [weak self] _ in self?.transportFailed(generation: current) }
        handshakeTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func sendHello(generation current: Int) {
        guard wanted, generation == current else { return }
        var hello = RelayMessage(type: "hello")
        hello.version = RelayProtocol.version; hello.name = displayName; hello.capabilities = ["emote-png-v1", "relative-position-v1"]
        hello.action = token == nil ? action : "resume"
        hello.room = room.isEmpty ? nil : room; hello.token = token
        send(hello, generation: current)
    }
    private func receive(_ task: URLSessionWebSocketTask, generation current: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.wanted, self.generation == current else { return }
                switch result {
                case .failure(let error):
                    self.onTransportError?(error)
                    self.transportFailed(generation: current)
                case .success(let frame):
                    let data: Data
                    switch frame {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    @unknown default: self.terminal("服务器返回了不支持的消息。"); return
                    }
                    guard let packet = try? JSONDecoder().decode(RelayMessage.self, from: data) else {
                        self.terminal("服务器消息格式不正确，请检查中继版本。"); return
                    }
                    self.handle(packet)
                    if self.wanted && self.generation == current { self.receive(task, generation: current) }
                }
            }
        }
    }
    private func handle(_ packet: RelayMessage) {
        switch packet.type {
        case "welcome":
            guard state != .connected, packet.version == RelayProtocol.version,
                  let code = packet.room, RelayProtocol.validRoomCode(code),
                  let credential = packet.token, !credential.isEmpty,
                  let id = packet.memberID, !id.isEmpty, let roster = packet.peers else {
                terminal("中继协议不兼容，请更新客户端和服务端。"); return
            }
            supportsEmotes = packet.capabilities?.contains("emote-png-v1") == true
            room = code; roomInput = formattedRoom; token = credential; memberID = id
            peers = roster; state = .connected; retryCount = 0
            handshakeTimer?.invalidate(); handshakeTimer = nil
            updateStatus()
            if let endpoint, !resumeStore.save(RelaySavedSession(endpoint: endpoint.absoluteString, room: code, token: credential, memberID: id)) {
                status += " 会话未能保存，请解锁登录钥匙串后重新连接。"
            }
            startHeartbeat(); onConnected?()
        case "peers":
            guard state == .connected, let roster = packet.peers else { return }
            peers = roster; updateStatus()
        case "ping":
            guard state == .connected, let rawID = packet.eventID, UUID(uuidString: rawID) != nil,
                  let kind = packet.kind, let sender = packet.sender,
                  sender.id != memberID, peers.contains(sender), sender.name.unicodeScalars.count <= 24 else { return }
            let id = rawID.lowercased()
            guard !recentIDs.contains(id) else { return }
            recentIDs.append(id)
            if recentIDs.count > 128 { recentIDs.removeFirst() }
            guard receiveEnabled else { return }
            guard let position = packet.position, position.isValid else {
                positionWarning = "朋友的信号缺少有效落点，未显示。请双方更新后重试。"; return
            }
            positionWarning = nil
            onPing?(kind, sender.name); onPositionedPing?(kind, sender.name, position.point)
        case "emote":
            guard state == .connected, receiveEnabled, let rawID = packet.eventID, UUID(uuidString: rawID) != nil,
                  let emote = packet.emote, emote.isValid, let sender = packet.sender,
                  sender.id != memberID, peers.contains(sender), !recentIDs.contains(rawID.lowercased()) else { return }
            recentIDs.append(rawID.lowercased()); if recentIDs.count > 128 { recentIDs.removeFirst() }
            guard let position = packet.position, position.isValid else {
                positionWarning = "朋友的表情缺少有效落点，未显示。请双方更新后重试。"; return
            }
            positionWarning = nil
            onEmote?(emote, sender.name); onPositionedEmote?(emote, sender.name, position.point)
        case "error":
            if ["room_missing", "resume_expired", "invalid_token"].contains(packet.code ?? ""), let endpoint { resumeStore.remove(endpoint) }
            if ["rate_limited", "emote_unsupported"].contains(packet.code ?? "") { status = packet.message ?? "发送太快，请稍等一下。" }
            else { terminal(packet.message ?? "房间连接失败。") }
        default: terminal("服务器返回了未知消息，请检查中继版本。")
        }
    }
    private func updateStatus() {
        let friends = peers.filter { $0.id != memberID }.map(\.name)
        status = friends.isEmpty ? "房间已创建，等待朋友加入。" : "已连接：\(friends.joined(separator: "、"))"
    }
    private func send(_ packet: RelayMessage, generation current: Int) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        guard wanted, let data = try? encoder.encode(packet), data.count <= RelayProtocol.maxMessageBytes,
              let text = String(data: data, encoding: .utf8) else { return }
        if let pinnedSocket {
            pinnedSocket.send(data) { [weak self] error in
                if error != nil { self?.transportFailed(generation: current) }
            }
            return
        }
        guard let socket else { return }
        socket.send(.string(text)) { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.transportFailed(generation: current) } }
        }
    }
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let current = generation
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.generation == current else { return }
            let completion: (Error?) -> Void = { [weak self] error in
                if error != nil { DispatchQueue.main.async { self?.transportFailed(generation: current) } }
            }
            if let pinnedSocket = self.pinnedSocket { pinnedSocket.sendPing(completion: completion) }
            else { self.socket?.sendPing(pongReceiveHandler: completion) }
        }
        heartbeatTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func transportFailed(generation current: Int) {
        guard wanted, generation == current else { return }
        closeTransport(); peers = []; state = .reconnecting
        retryCount += 1
        status = "连接中断，正在重新连接…（\(retryCount)）"
        let work = DispatchWorkItem { [weak self] in self?.open() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now()+min(pow(2, Double(min(retryCount-1, 4))), 10), execute: work)
    }
    private func terminal(_ message: String) {
        wanted = false; reconnectWork?.cancel(); reconnectWork = nil
        closeTransport(); token = nil; peers = []; room = ""; memberID = ""
        state = .failed; status = message; onFailure?(message)
    }
    private func closeTransport(leaving: Bool = false) {
        generation += 1; supportsEmotes = false; positionWarning = nil
        handshakeTimer?.invalidate(); handshakeTimer = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        let oldSocket = socket, oldSession = session
        let oldPinned = pinnedSocket
        pinnedSocket = nil
        socket = nil; session = nil
        if leaving, let oldPinned {
            oldPinned.send(Data("{\"type\":\"leave\"}".utf8)) { _ in oldPinned.cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now()+2) { oldPinned.cancel() }
        } else { oldPinned?.cancel() }
        if leaving, let oldSocket, oldSocket.state == .running {
            oldSocket.send(.string("{\"type\":\"leave\"}")) { _ in
                oldSocket.cancel(with: .normalClosure, reason: nil); oldSession?.invalidateAndCancel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now()+2) {
                oldSocket.cancel(with: .normalClosure, reason: nil); oldSession?.invalidateAndCancel()
            }
        } else {
            oldSocket?.cancel(with: .goingAway, reason: nil); oldSession?.invalidateAndCancel()
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {}
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.socket === webSocketTask else { return }
            self.transportFailed(generation: self.generation)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.socket === task else { return }
            if let error { self.onTransportError?(error) }
            self.transportFailed(generation: self.generation)
        }
    }
}
