import Foundation
import PingCore

/// Headless LAN diagnostics. Never touches NSApplication, the event tap, the
/// menu bar or any window; only advertises, browses and prints.
///   LoLPing --lan-listen --room R [--name N] [--seconds S]
///   LoLPing --lan-send --room R [--name N] [--kind K] [--nx X --ny Y] [--count C] [--seconds S]
enum LANCommandLine {
    static func run(_ arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index+1 else { return nil }
            return arguments[index+1]
        }
        let sending = arguments.contains("--lan-send")
        let room = LANProtocol.normalizeRoomCode(value("--room") ?? "")
        guard !room.isEmpty else { print("ERROR --room is required"); exit(64) }
        let cleanedName = LANProtocol.sanitizeName(value("--name") ?? "")
        let name = cleanedName.isEmpty ? AppModel.defaultNickname : cleanedName
        let seconds = value("--seconds").flatMap(Double.init) ?? (sending ? 8 : 15)
        let session = LANSession()
        print("STATUS \(sending ? "send" : "listen") room=\(room) hash=\(LANProtocol.roomHash(room)) name=\(name) id=\(session.instanceID)")
        session.onStatus = { print("STATUS \($0.summary)") }
        session.onLog = { print("LOG \($0)") }
        session.onPeers = { print("STATUS peers connected=\($0.connected) online=\($0.online.joined(separator: ","))") }
        session.onHello = { print("RECV hello from=\($0.name) seq=\($0.seq)") }
        session.onReceive = { message, playSound in
            guard case .ping(let kind, let p) = message.body else { return }
            print("RECV ping from=\(message.name) kind=\(kind.rawValue) nx=\(String(format: "%.4f", p.x)) ny=\(String(format: "%.4f", p.y)) seq=\(message.seq) sound=\(playSound ? "yes" : "no")")
        }
        var sender: Sender?
        if sending {
            guard let kind = PingKind(rawValue: value("--kind") ?? "generic") else {
                print("ERROR unknown --kind; use one of: \(PingKind.allCases.map(\.rawValue).joined(separator: " "))"); exit(64)
            }
            let position = CGPoint(x: value("--nx").flatMap(Double.init) ?? 0.5, y: value("--ny").flatMap(Double.init) ?? 0.5)
            let count = max(1, value("--count").flatMap(Int.init) ?? 1)
            sender = Sender(session: session, kind: kind, position: position, count: count)
            sender?.begin()
        }
        session.start(room: room, name: name)
        DispatchQueue.main.asyncAfter(deadline: .now()+seconds) {
            // A send already in progress finishes and exits on its own; the
            // backstop only guards against a sequence that never completes.
            if let sender, sender.started {
                DispatchQueue.main.asyncAfter(deadline: .now()+5+0.3*Double(sender.count)) { print("SENT incomplete"); exit(2) }
                return
            }
            if sending { print("SENT none: no same-room peer became ready within \(Int(seconds))s") }
            session.stop()
            exit(sending ? 2 : 0)
        }
        dispatchMain()
    }

    /// Waits for the first ready peer, then sends `count` pings 300 ms apart.
    private final class Sender {
        let session: LANSession, kind: PingKind, position: CGPoint, count: Int
        private(set) var started = false
        private var reached = 0
        init(session: LANSession, kind: PingKind, position: CGPoint, count: Int) {
            self.session = session; self.kind = kind; self.position = position; self.count = count
        }
        func begin() {
            let previous = session.onPeers
            session.onPeers = { [self] peers in
                previous?(peers)
                guard !started, peers.connected > 0 else { return }
                started = true
                send(1)
            }
        }
        private func send(_ index: Int) {
            session.sendPing(kind, at: position) { [self] delivered in
                reached = max(reached, delivered)
                print("SENT ping \(index)/\(count) kind=\(kind.rawValue) nx=\(position.x) ny=\(position.y) peers=\(delivered)")
                guard index < count else { finish(); return }
                DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { self.send(index+1) }
            }
        }
        private func finish() {
            session.sendHello { [self] delivered in
                print("SENT hello peers=\(delivered)")
                // Give the datagrams a moment to leave before cancelling.
                DispatchQueue.main.asyncAfter(deadline: .now()+0.5) {
                    self.session.stop()
                    exit(self.reached > 0 ? 0 : 2)
                }
            }
        }
    }
}
