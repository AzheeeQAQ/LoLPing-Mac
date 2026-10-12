import Foundation
import Network
import Security

/// TLS-only WebSocket for the one relay whose private CA is bundled with App.
/// All connection callbacks and mutable state run on the main queue.
final class PinnedRelaySocket {
    var onOpen: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let connection: NWConnection
    private var stopped = false

    init?(endpoint: URL) {
        guard endpoint.scheme == "wss", let host = endpoint.host,
              let port = endpoint.port, RelayServerTrust.matches(host: host, port: port),
              RelayServerTrust.anchor != nil else { return nil }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, peerTrust, complete in
            let trust = sec_trust_copy_ref(peerTrust).takeRetainedValue()
            complete(RelayServerTrust.evaluate(trust, host: host, port: port) == true)
        }, DispatchQueue.global(qos: .userInitiated))
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 4096
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: .url(endpoint), using: parameters)
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready: self.onOpen?(); self.receive()
            case .failed(let error), .waiting(let error): self.fail(error)
            default: break
            }
        }
        connection.start(queue: .main)
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard !stopped else { completion(Self.closedError); return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "relay-text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { completion($0) })
    }
    func sendPing(completion: @escaping (Error?) -> Void) {
        guard !stopped else { completion(Self.closedError); return }
        let waiter = PingWaiter(completion)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(.main) { error in waiter.finish(error) }
        let context = NWConnection.ContentContext(identifier: "relay-ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in if let error { waiter.finish(error) } })
        DispatchQueue.main.asyncAfter(deadline: .now()+10) {
            waiter.finish(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        }
    }
    func cancel() { stopped = true; connection.stateUpdateHandler = nil; connection.cancel() }
    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.stopped else { return }
            if let error { self.fail(error); return }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                self.fail(Self.closedError); return
            }
            switch metadata.opcode {
            case .text:
                guard let data, data.count <= 4096 else { self.fail(Self.closedError); return }
                self.onMessage?(data)
            case .ping, .pong: break
            case .close: self.fail(Self.closedError); return
            default: self.fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse)); return
            }
            if !self.stopped { self.receive() }
        }
    }
    private func fail(_ error: Error) {
        guard !stopped else { return }
        cancel(); onFailure?(error)
    }
    private static let closedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
    private final class PingWaiter {
        private var callback: ((Error?) -> Void)?
        init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
        func finish(_ error: Error?) {
            let action = callback; callback = nil; action?(error)
        }
    }
}
