import Foundation
import Network
import PingCore

/// Bonjour + UDP transport for 局域网互发. Every Network.framework callback and
/// all mutable state stay on `queue`; the `on…` handlers are always called on
/// the main queue. No AppKit here, so the headless CLI modes can share it.
final class LANSession {
    enum Status: Equatable {
        case stopped, starting, ready
        case waiting(String), failed(String)
        var problem: String? {
            switch self {
            case .waiting(let text), .failed(let text): return text
            default: return nil
            }
        }
        var summary: String {
            switch self {
            case .stopped: return "stopped"
            case .starting: return "starting"
            case .ready: return "ready"
            case .waiting(let text): return "waiting: \(text)"
            case .failed(let text): return "failed: \(text)"
            }
        }
    }
    struct Peers: Equatable {
        var online: [String] = []
        var connected = 0
    }
    private struct Config { let room: String; let name: String }
    private struct Outgoing {
        let endpoint: NWEndpoint, label: String
        var connection: NWConnection, ready = false, opened: TimeInterval
        /// A fresh connection to the same service; it replaces `connection` once ready.
        var standby: NWConnection?, standbyDialed: TimeInterval = 0
    }
    private struct Flow { let connection: NWConnection; var lastActive: TimeInterval }
    private final class Tally { var remaining: Int; var delivered = 0; init(_ count: Int) { remaining = count } }

    let instanceID = UUID().uuidString
    var onStatus: ((Status) -> Void)?
    var onPeers: ((Peers) -> Void)?
    /// Valid pings that passed dedupe and rate limits.
    var onReceive: ((LANMessage, _ playSound: Bool) -> Void)?
    /// Hellos are only forwarded (to main) when someone listens; the app does not.
    var onHello: ((LANMessage) -> Void)?
    var onLog: ((String) -> Void)?

    private static let redialDelay: TimeInterval = 1
    private static let refreshInterval: TimeInterval = 30
    private let queue = DispatchQueue(label: "local.allentu.LoLPing.lan")
    private var config: Config?
    private var generation = 0
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var listenerReady = false, browserReady = false
    private var listenerProblem: String?, browserProblem: String?
    private var results: Set<NWBrowser.Result> = []
    private var outgoing: [String: Outgoing] = [:]
    private var incoming: [Int: Flow] = [:]
    private var flowCount = 0
    private var flows = LANFlowTracker<Int>()
    private var presence = LANPresence()
    private var limiter = LANRateLimiter()
    private var peersQueued = false
    private var seq = 0
    private var ticker: DispatchSourceTimer?
    private var retry: DispatchWorkItem?
    private var backoff: TimeInterval = 5
    private var status: Status = .stopped
    private var peers = Peers()
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Restarts from scratch; a changed room or nickname always goes through here.
    func start(room: String, name: String) {
        queue.async {
            self.teardown()
            self.config = Config(room: LANProtocol.roomHash(room), name: name)
            self.backoff = 5
            self.launch()
        }
    }
    /// Synchronous so that app quit really cancels the listener before exit.
    func stop() {
        queue.sync {
            self.config = nil
            self.teardown()
            self.publish(.stopped)
        }
    }
    func sendPing(_ kind: PingKind, at position: CGPoint, completion: ((Int) -> Void)? = nil) {
        queue.async { self.broadcast(kind: kind, position: position, completion: completion) }
    }
    func sendHello(completion: ((Int) -> Void)? = nil) {
        queue.async { self.broadcast(kind: nil, position: nil, completion: completion) }
    }

    // MARK: - Lifecycle (queue only)

    private func launch() {
        guard let config else { return }
        generation += 1
        let generation = generation
        publish(.starting)
        do {
            let listener = try NWListener(using: .udp)
            listener.service = NWListener.Service(name: LANProtocol.serviceName(nickname: config.name, instanceID: instanceID),
                                                  type: LANProtocol.serviceType, domain: nil,
                                                  txtRecord: NWTXTRecord(["v": "\(LANProtocol.version)", "id": instanceID, "room": config.room]))
            listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state, generation) }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, generation) }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            fail(Self.describe(error))
            return
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LANProtocol.serviceType, domain: nil), using: .udp)
        browser.stateUpdateHandler = { [weak self] state in self?.browserChanged(state, generation) }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, generation == self.generation else { return }
            self.results = results; self.reconcile()
        }
        self.browser = browser
        browser.start(queue: queue)
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now()+LANProtocol.helloInterval, repeating: LANProtocol.helloInterval)
        ticker.setEventHandler { [weak self] in self?.tick() }
        self.ticker = ticker
        ticker.resume()
    }
    private func teardown() {
        generation += 1
        retry?.cancel(); retry = nil
        ticker?.cancel(); ticker = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        outgoing.values.forEach { $0.connection.cancel(); $0.standby?.cancel() }; outgoing.removeAll()
        incoming.values.forEach { $0.connection.cancel() }; incoming.removeAll(); flows.removeAll()
        results.removeAll()
        listenerReady = false; browserReady = false; listenerProblem = nil; browserProblem = nil
        presence.removeAll()
        publishPeers()
    }
    /// Listener or browser failures restart everything after 5, 10, 20, 30 s.
    private func fail(_ message: String) {
        teardown()
        guard config != nil else { return }
        let delay = backoff
        backoff = min(backoff*2, 30)
        publish(.failed("\(message)（\(Int(delay)) 秒后重试）"))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.config != nil else { return }
            self.retry = nil; self.launch()
        }
        retry = work
        queue.asyncAfter(deadline: .now()+delay, execute: work)
    }
    private func listenerChanged(_ state: NWListener.State, _ generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .ready: listenerReady = true; listenerProblem = nil; log("listener ready on port \(listener?.port?.rawValue ?? 0)")
        case .waiting(let error): listenerReady = false; listenerProblem = Self.describe(error)
        case .failed(let error): fail(Self.describe(error)); return
        default: break
        }
        updateStatus()
    }
    private func browserChanged(_ state: NWBrowser.State, _ generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .ready: browserReady = true; browserProblem = nil
        case .waiting(let error): browserReady = false; browserProblem = Self.describe(error)
        case .failed(let error): fail(Self.describe(error)); return
        default: break
        }
        updateStatus()
    }
    private func updateStatus() {
        if let problem = listenerProblem ?? browserProblem { publish(.waiting(problem)) }
        else if listenerReady && browserReady { backoff = 5; publish(.ready) }
        else { publish(.starting) }
    }

    // MARK: - Peers (queue only)

    /// One outgoing connection per same-room peer instance, whatever the number
    /// of interfaces Bonjour reports it on.
    private func reconcile() {
        guard let config else { return }
        var endpoints: [String: [NWEndpoint]] = [:]
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let id = txt["id"], id != instanceID,
                  txt["room"] == config.room, txt["v"] == "\(LANProtocol.version)" else { continue }
            endpoints[id, default: []].append(result.endpoint)
        }
        for (id, peer) in outgoing where !(endpoints[id] ?? []).contains(peer.endpoint) {
            log("peer gone \(peer.label)")
            peer.connection.cancel(); peer.standby?.cancel(); outgoing[id] = nil
        }
        for (id, candidates) in endpoints where outgoing[id] == nil {
            let endpoint = candidates.min { "\($0)" < "\($1)" }!
            let label: String
            if case .service(let name, _, _, _) = endpoint { label = name } else { label = "\(endpoint)" }
            outgoing[id] = Outgoing(endpoint: endpoint, label: label, connection: dial(id, endpoint), opened: now)
        }
        publishPeers()
    }
    /// Dialing a `.service` endpoint resolves the peer's current address and port.
    private func dial(_ id: String, _ endpoint: NWEndpoint) -> NWConnection {
        let generation = generation
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, generation == self.generation else { return }
            self.outgoingChanged(id, connection, state)
        }
        connection.start(queue: queue)
        return connection
    }
    private func outgoingChanged(_ id: String, _ connection: NWConnection, _ state: NWConnection.State) {
        guard var peer = outgoing[id] else { return }
        if peer.standby === connection {
            switch state {
            case .ready:
                peer.connection.cancel()
                peer.connection = connection; peer.ready = true; peer.opened = now; peer.standby = nil
                outgoing[id] = peer
                log("peer refreshed \(peer.label)")
            case .waiting, .failed:
                connection.cancel(); outgoing[id]?.standby = nil
            default: break
            }
            publishPeers()
            return
        }
        guard peer.connection === connection else { return }
        switch state {
        case .ready:
            outgoing[id]?.ready = true
            log("peer ready \(peer.label)")
            send(packet(kind: nil, position: nil), to: [(id, connection)], completion: nil)
        case .waiting(let error):
            outgoing[id]?.ready = false
            log("peer waiting \(peer.label): \(Self.describe(error))")
        case .failed(let error):
            redial(id, because: Self.describe(error))
        default: break
        }
        publishPeers()
    }
    /// A UDP connection stays `.ready` after its peer's socket is gone (for
    /// example the friend toggled 局域网联机 and came back on a new port under
    /// the same Bonjour name), so failed sends and `.failed` both drop it and
    /// dial the service again a moment later.
    private func redial(_ id: String, because reason: String) {
        guard let peer = outgoing[id] else { return }
        log("peer redial \(peer.label): \(reason)")
        peer.connection.cancel(); peer.standby?.cancel(); outgoing[id] = nil
        let generation = generation
        queue.asyncAfter(deadline: .now()+Self.redialDelay) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.reconcile()
        }
        publishPeers()
    }
    private func accept(_ connection: NWConnection, _ generation: Int) {
        guard generation == self.generation else { connection.cancel(); return }
        if incoming.count >= 64, let oldest = incoming.min(by: { $0.value.lastActive < $1.value.lastActive }) {
            dropFlow(oldest.key)
        }
        flowCount += 1
        let key = flowCount
        incoming[key] = Flow(connection: connection, lastActive: now)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, generation == self.generation else { return }
            switch state {
            case .failed, .cancelled: self.dropFlow(key)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, key: key, generation: generation)
    }
    private func dropFlow(_ key: Int) {
        incoming.removeValue(forKey: key)?.connection.cancel()
        flows.forget(key)
    }
    private func receive(on connection: NWConnection, key: Int, generation: Int) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, generation == self.generation, self.incoming[key] != nil else { return }
            if let data, !data.isEmpty {
                self.incoming[key]?.lastActive = self.now
                self.handle(data, flow: key)
            }
            if error == nil { self.receive(on: connection, key: key, generation: generation) }
            else { self.dropFlow(key) }
        }
    }
    private func handle(_ data: Data, flow: Int) {
        guard let config else { return }
        guard let message = LANProtocol.decode(data, room: config.room, selfID: instanceID) else {
            log("drop invalid packet (\(data.count) bytes)")
            return
        }
        var pingSeq: Int?
        if case .ping = message.body { pingSeq = message.seq }
        switch flows.check(flow, sender: message.sender, pingSeq: pingSeq) {
        case .accept: break
        case .otherSender: log("drop packet: sender id changed on one socket"); return
        case .duplicate: log("drop duplicate ping seq=\(message.seq)"); return
        }
        let time = now
        guard presence.saw(message.sender, name: message.name, at: time) else { log("drop packet: too many peers"); return }
        switch message.body {
        case .hello:
            if onHello != nil { DispatchQueue.main.async { [weak self] in self?.onHello?(message) } }
        case .ping:
            switch limiter.admit(message.sender, at: time) {
            case .withSound: deliver(message, playSound: true)
            case .silent: deliver(message, playSound: false)
            case .drop: log("drop rate-limited ping from \(message.name)")
            }
        }
        queuePeers()
    }
    private func tick() {
        send(packet(kind: nil, position: nil), to: readyPeers, completion: nil)
        let time = now
        for id in presence.prune(at: time) { limiter.forget(id) }
        for (key, entry) in incoming where time-entry.lastActive > 30 { dropFlow(key) }
        // Backstop for address changes nothing reports (a new DHCP lease, Wi-Fi
        // to Ethernet): every 30 s dial each peer again, keeping the old
        // connection until the new one is ready. A stuck standby is replaced.
        for (id, peer) in outgoing where time-peer.opened >= Self.refreshInterval
            && (peer.standby == nil || time-peer.standbyDialed >= 10) {
            peer.standby?.cancel()
            outgoing[id]?.standby = dial(id, peer.endpoint); outgoing[id]?.standbyDialed = time
        }
        publishPeers()
    }

    // MARK: - Sending (queue only)

    private func packet(kind: PingKind?, position: CGPoint?) -> LANPacket? {
        guard let config else { return nil }
        seq += 1
        if let kind, let position {
            return .ping(kind, at: position, id: instanceID, name: config.name, room: config.room, seq: seq)
        }
        return .hello(id: instanceID, name: config.name, room: config.room, seq: seq)
    }
    private var readyPeers: [(id: String, connection: NWConnection)] {
        outgoing.filter(\.value.ready).map { ($0.key, $0.value.connection) }
    }
    private func broadcast(kind: PingKind?, position: CGPoint?, completion: ((Int) -> Void)?) {
        send(packet(kind: kind, position: position), to: readyPeers, completion: completion)
    }
    /// Reports how many peers accepted the datagram (UDP: no delivery receipt).
    private func send(_ packet: LANPacket?, to peers: [(id: String, connection: NWConnection)], completion: ((Int) -> Void)?) {
        guard let packet, let data = LANProtocol.encode(packet), !peers.isEmpty else {
            if let completion { DispatchQueue.main.async { completion(0) } }
            return
        }
        let tally = Tally(peers.count)
        for (id, connection) in peers {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error { self?.sendFailed(id, connection, error) } else { tally.delivered += 1 }
                tally.remaining -= 1
                if tally.remaining == 0, let completion {
                    let delivered = tally.delivered
                    DispatchQueue.main.async { completion(delivered) }
                }
            })
        }
    }

    /// ICMP errors from a connected UDP socket surface on a later send.
    private func sendFailed(_ id: String, _ connection: NWConnection, _ error: NWError) {
        log("send failed: \(Self.describe(error))")
        guard outgoing[id]?.connection === connection, case .posix(let code) = error,
              [.ECONNREFUSED, .EHOSTDOWN, .EHOSTUNREACH, .ENETUNREACH].contains(code) else { return }
        redial(id, because: Self.describe(error))
    }

    // MARK: - Reporting

    private func publish(_ next: Status) {
        guard next != status else { return }
        status = next
        log("status \(next.summary)")
        DispatchQueue.main.async { [weak self] in self?.onStatus?(next) }
    }
    /// Incoming packets coalesce peer updates to at most four per second.
    private func queuePeers() {
        guard !peersQueued else { return }
        peersQueued = true
        queue.asyncAfter(deadline: .now()+0.25) { [weak self] in
            self?.peersQueued = false; self?.publishPeers()
        }
    }
    private func publishPeers() {
        let next = Peers(online: presence.online(at: now).map(\.name), connected: outgoing.values.filter(\.ready).count)
        guard next != peers else { return }
        peers = next
        DispatchQueue.main.async { [weak self] in self?.onPeers?(next) }
    }
    private func deliver(_ message: LANMessage, playSound: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onReceive?(message, playSound) }
    }
    private func log(_ text: String) {
        guard onLog != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.onLog?(text) }
    }
    static func describe(_ error: Error) -> String {
        if let error = error as? NWError {
            switch error {
            case .dns(let code) where code == -65570:
                return "本地网络权限被拒绝：请在 系统设置 → 隐私与安全性 → 本地网络 中允许 LoLPing"
            case .posix(let code) where code == .EHOSTUNREACH || code == .EPERM || code == .EACCES:
                return "无法访问本地网络（\(code)），请检查本地网络权限或防火墙"
            case .posix(let code) where code == .ENETDOWN || code == .ENETUNREACH:
                return "网络不可用，请确认已连接 Wi-Fi"
            default: break
            }
        }
        return "局域网错误：\(error.localizedDescription)"
    }
}
