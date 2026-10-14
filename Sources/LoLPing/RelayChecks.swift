import Foundation
import PingCore

/// Uses the production client without input taps, overlays, audio or preferences.
enum RelayChecks {
    static func run(endpoint: String) -> Int32 {
        let a = RelayClient(defaults: nil), b = RelayClient(defaults: nil), c = RelayClient(defaults: nil)
        var phase = "initial", initialPings = 0, done = false, failure: String?
        var originalRoom = "", originalMember = ""
        func fail(_ message: String) { failure = message; done = true }
        for client in [a, b, c] {
            client.serverAddress = endpoint
            client.onFailure = { fail($0) }
            client.onTransportError = { error in
                let value = error as NSError
                print("Transport error: \(value.domain) \(value.code) \(value.localizedDescription)")
                if let nested = value.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("Underlying error: \(nested.domain) \(nested.code) \(nested.localizedDescription)")
                }
            }
        }
        a.displayName = "甲"; b.displayName = "乙"; c.displayName = "丙"
        func beginResumeIfReady() {
            guard initialPings == 2, phase == "initial" else { return }
            print("PASS Swift clients: create/join and two-way signals with sender names")
            phase = "muted"; b.receiveEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { a.sendPing(.push, position: CGPoint(x: 0.23, y: 0.71)) }
            DispatchQueue.main.asyncAfter(deadline: .now()+1.5) {
                guard !done else { return }
                print("PASS Swift clients: receive switch suppresses signals")
                phase = "resuming"; b.receiveEnabled = true; b.reconnectAfterWake()
            }
        }
        a.onConnected = {
            guard phase == "initial", b.state == .idle else { return }
            originalRoom = a.room; b.roomInput = a.formattedRoom; b.joinRoom()
        }
        b.onConnected = {
            if phase == "initial" {
                originalMember = b.memberID
                DispatchQueue.main.asyncAfter(deadline: .now()+0.1) {
                    a.sendPing(.missing, position: CGPoint(x: 0.23, y: 0.71)); b.sendPing(.assist, position: CGPoint(x: 0.23, y: 0.71))
                }
            } else if phase == "resuming" {
                guard b.room == originalRoom, b.memberID == originalMember else { fail("Resume changed identity"); return }
                b.sendPing(.enemyVision, position: CGPoint(x: 0.23, y: 0.71))
            }
        }
        a.onPing = { kind, sender in
            if phase == "initial" {
                guard kind == .assist, sender == "乙" else { fail("Incorrect signal received by A"); return }
                initialPings += 1; beginResumeIfReady()
            } else if phase == "resuming" {
                guard kind == .enemyVision, sender == "乙" else { fail("Incorrect resumed signal"); return }
                print("PASS Swift clients: automatic reconnect/resume preserves identity and delivery")
                phase = "replacement"; b.disconnect()
                DispatchQueue.main.asyncAfter(deadline: .now()+0.3) { c.roomInput = originalRoom; c.joinRoom() }
            } else { fail("Unexpected signal or sender echo") }
        }
        b.onPing = { kind, sender in
            guard phase == "initial", kind == .missing, sender == "甲" else { fail("Unexpected signal received by B"); return }
            initialPings += 1; beginResumeIfReady()
        }
        c.onConnected = {
            guard phase == "replacement" else { fail("Unexpected replacement connection"); return }
            DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { a.sendPing(.allIn, position: CGPoint(x: 0.23, y: 0.71)) }
        }
        c.onPing = { kind, sender in
            guard phase == "replacement", kind == .allIn, sender == "甲" else { fail("Incorrect replacement signal"); return }
            print("PASS Swift clients: explicit leave frees the seat for a new friend")
            done = true
        }
        a.createRoom()
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !done { failure = "Timed out: \(a.status) / \(b.status) / \(c.status)" }
        for client in [a, b, c] { client.disconnect() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if let failure { print("FAIL Relay check: \(failure)"); return 1 }
        print("All production Swift relay client checks passed."); return 0
    }
}
