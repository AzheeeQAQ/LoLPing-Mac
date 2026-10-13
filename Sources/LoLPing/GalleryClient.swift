import Foundation
import AppKit
import Combine
import CryptoKit
import PingCore

struct GalleryItem: Codable, Identifiable {
    let id: String
    let name: String
    let uploader: String
    let createdAt: Int64
    var isValid: Bool {
        id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) } &&
        name == RelayProtocol.displayName(name) && uploader == RelayProtocol.displayName(uploader) && createdAt > 0
    }
}
struct GalleryMessage: Codable {
    var type: String
    var requestID = UUID().uuidString
    var cursor: Int?
    var id: String?
    var uploader: String?
    var emote: EmotePayload?
    var ownerToken: String?
    var items: [GalleryItem]?
    var item: GalleryItem?
    var nextCursor: Int?
    var total: Int?
    var duplicate: Bool?
    var owned: Bool?
    var code: String?
    var message: String?
}

/// A bounded request on an independent socket: public browsing never creates,
/// joins or switches a private signal room. All callbacks run on the main queue.
private final class GalleryRequest {
    let endpoint: URL
    let packet: GalleryMessage
    private var callback: ((Result<GalleryMessage, Error>) -> Void)?
    private var pinned: PinnedRelaySocket?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var timer: Timer?
    init(endpoint: URL, packet: GalleryMessage, completion: @escaping (Result<GalleryMessage, Error>) -> Void) {
        self.endpoint = endpoint; self.packet = packet; callback = completion
    }
    func start() {
        guard let data = try? JSONEncoder().encode(packet), data.count <= RelayProtocol.maxMessageBytes else {
            finish(.failure(Self.problem("图片请求过大。"))); return
        }
        let timeout = Timer(timeInterval: 15, repeats: false) { [weak self] _ in self?.finish(.failure(Self.problem("公共图片库连接超时，请刷新重试。"))) }
        timer = timeout; RunLoop.main.add(timeout, forMode: .common)
        if let host = endpoint.host, let port = endpoint.port, RelayServerTrust.matches(host: host, port: port) {
            guard let transport = PinnedRelaySocket(endpoint: endpoint) else { finish(.failure(Self.problem("服务器证书配置无效。"))); return }
            pinned = transport
            transport.onOpen = { [weak self] in transport.send(data) { error in if let error { self?.finish(.failure(error)) } } }
            transport.onMessage = { [weak self] in self?.receive($0) }
            transport.onFailure = { [weak self] in self?.finish(.failure($0)) }
            transport.start()
        } else {
            let config = URLSessionConfiguration.ephemeral; config.tlsMinimumSupportedProtocolVersion = .TLSv12
            config.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: config); self.session = session
            let task = session.webSocketTask(with: endpoint); socket = task
            task.maximumMessageSize = RelayProtocol.maxMessageBytes; task.resume()
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                if let error { DispatchQueue.main.async { self?.finish(.failure(error)) } }
            }
            task.receive { [weak self] result in DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error): self.finish(.failure(error))
                case .success(let frame):
                    switch frame {
                    case .string(let text): self.receive(Data(text.utf8))
                    case .data(let data): self.receive(data)
                    @unknown default: self.finish(.failure(Self.problem("图片库返回了不支持的消息。")))
                    }
                }
            } }
        }
    }
    private func receive(_ data: Data) {
        guard data.count <= RelayProtocol.maxMessageBytes,
              let reply = try? JSONDecoder().decode(GalleryMessage.self, from: data),
              reply.type == "gallery_result", reply.requestID == packet.requestID else {
            finish(.failure(Self.problem("服务器不支持公共图片库，请更新服务器。"))); return
        }
        if reply.code != nil { finish(.failure(Self.problem(reply.message ?? "公共库请求失败，请稍后重试。"))) }
        else { finish(.success(reply)) }
    }
    func cancel() { finish(.failure(Self.problem("公共图片库已断开。"))) }
    private func finish(_ result: Result<GalleryMessage, Error>) {
        guard let completion = callback else { return }
        callback = nil; timer?.invalidate(); timer = nil
        pinned?.onOpen = nil; pinned?.onMessage = nil; pinned?.onFailure = nil; pinned?.cancel(); pinned = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        completion(result)
    }
    static func problem(_ text: String) -> NSError { NSError(domain: "LoLPingGallery", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

final class GalleryClient: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []
    @Published private(set) var payloads: [String: EmotePayload] = [:]
    @Published private(set) var status = "点击刷新，浏览此服务器的公共图片。"
    @Published private(set) var refreshing = false
    @Published private(set) var mutating = false
    @Published private(set) var endpoint: URL?
    private let defaults: UserDefaults?
    private var active: GalleryRequest?
    private var queue: [(GalleryMessage, (Result<GalleryMessage, Error>) -> Void)] = []
    private var loading = Set<String>()
    private var generation = 0
    private var images: [String: NSImage] = [:]
    private var pageItems: [GalleryItem] = []
    private var listGeneration = 0
    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }
    private var ownershipKey: String { "galleryOwners-"+EmoteLibrary.hash(Data((endpoint?.absoluteString ?? "").utf8)) }
    private var owners: [String: String] { defaults?.dictionary(forKey: ownershipKey) as? [String: String] ?? [:] }
    func canDelete(_ id: String) -> Bool { owners[id] != nil }
    func configure(_ address: String) {
        guard let url = RelayProtocol.endpoint(address) else { disconnect(); status = "请输入有效的服务器地址。"; return }
        if endpoint != url { disconnect(); endpoint = url }
    }
    func disconnect() {
        generation += 1; listGeneration += 1
        queue.removeAll(); let request = active; active = nil; request?.cancel()
        endpoint = nil; items = []; payloads = [:]; images = [:]; loading = []
        refreshing = false; mutating = false; status = "公共图片库已断开。"
    }
    func refresh() {
        guard endpoint != nil, !refreshing else { return }
        refreshing = true; pageItems = []; listGeneration += 1
        status = "正在加载公共图片库…"; loadPage(0, version: listGeneration)
    }
    private func loadPage(_ cursor: Int, version: Int) {
        var packet = GalleryMessage(type: "gallery_list"); packet.cursor = cursor
        request(packet, priority: true) { [weak self] result in
            guard let self, self.listGeneration == version else { return }
            switch result {
            case .failure(let error): self.refreshing = false; self.status = error.localizedDescription
            case .success(let reply):
                guard let entries = reply.items, entries.count <= 50, entries.allSatisfy(\.isValid),
                      let total = reply.total, total >= 0, total <= 5000,
                      self.pageItems.count+entries.count <= 5000 else {
                    self.refreshing = false; self.status = "服务器图片列表无效。"; return
                }
                self.pageItems += entries
                if let next = reply.nextCursor {
                    guard next == cursor+50, next <= 5000, !entries.isEmpty else { self.refreshing = false; self.status = "图片分页无效。"; return }
                    self.loadPage(next, version: version)
                } else {
                    var seen = Set<String>(); self.items = self.pageItems.filter { seen.insert($0.id).inserted }
                    let current = Set(self.items.map(\.id)); self.payloads = self.payloads.filter { current.contains($0.key) }
                    self.images = self.images.filter { current.contains($0.key) }
                    self.refreshing = false; self.status = "公共库共 \(self.items.count) 张图片，连接此服务器的人均可使用。"
                }
            }
        }
    }
    func image(_ id: String) -> NSImage? { images[id] }
    func load(_ id: String, completion: ((EmotePayload?) -> Void)? = nil) {
        if let payload = payloads[id] { completion?(payload); return }
        // Explicit downloads may follow an already queued thumbnail request.
        guard !loading.contains(id) else {
            if let completion {
                var packet = GalleryMessage(type: "gallery_get"); packet.id = id
                request(packet, priority: true) { [weak self] result in self?.acceptImage(result, id: id, completion: completion) }
            }
            return
        }
        loading.insert(id)
        var packet = GalleryMessage(type: "gallery_get"); packet.id = id
        request(packet, priority: completion != nil) { [weak self] result in
            guard let self else { return }; self.loading.remove(id); self.acceptImage(result, id: id, completion: completion)
        }
    }
    private func acceptImage(_ result: Result<GalleryMessage, Error>, id: String, completion: ((EmotePayload?) -> Void)?) {
        switch result {
        case .failure(let error): status = error.localizedDescription; completion?(nil)
        case .success(let reply):
            guard let payload = reply.emote, payload.id == id, let image = EmoteLibrary.decode(payload) else {
                status = "公共库图片校验失败。"; completion?(nil); return
            }
            payloads[id] = payload; images[id] = image; completion?(payload)
        }
    }
    func upload(_ payload: EmotePayload, uploader: String) {
        guard endpoint != nil, !mutating, EmoteLibrary.decode(payload) != nil else { return }
        var saved = owners
        // Persist the upload credential first so a timeout/retry cannot lose ownership.
        let token = saved[payload.id] ?? (UUID().uuidString+UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        saved[payload.id] = token; defaults?.set(saved, forKey: ownershipKey)
        var packet = GalleryMessage(type: "gallery_upload"); packet.emote = payload
        packet.uploader = RelayProtocol.displayName(uploader); packet.ownerToken = token
        mutating = true; status = "正在上传到公共库…"
        request(packet, priority: true) { [weak self] result in
            guard let self else { return }; self.mutating = false
            switch result {
            case .failure(let error): self.status = error.localizedDescription
            case .success(let reply):
                guard let item = reply.item, item.isValid, item.id == payload.id else { self.status = "上传结果无效，请刷新重试。"; return }
                if reply.owned != true { var saved = self.owners; saved[payload.id] = nil; self.defaults?.set(saved, forKey: self.ownershipKey) }
                self.items.removeAll { $0.id == item.id }; self.items.insert(item, at: 0)
                self.payloads[payload.id] = payload; self.images[payload.id] = EmoteLibrary.decode(payload)
                self.status = reply.duplicate == true ? "公共库已有这张图片，未重复上传。" : "已上传「\(payload.name)」，所有连接此服务器的人均可看到。"
            }
        }
    }
    func remove(_ id: String) {
        guard endpoint != nil, !mutating, let token = owners[id] else { return }
        var packet = GalleryMessage(type: "gallery_delete"); packet.id = id; packet.ownerToken = token
        mutating = true; status = "正在从公共库删除…"
        request(packet, priority: true) { [weak self] result in
            guard let self else { return }; self.mutating = false
            switch result {
            case .failure(let error): self.status = error.localizedDescription
            case .success(let reply):
                guard reply.id == id else { self.status = "删除结果无效。"; return }
                self.items.removeAll { $0.id == id }; self.payloads[id] = nil; self.images[id] = nil
                var saved = self.owners; saved[id] = nil; self.defaults?.set(saved, forKey: self.ownershipKey)
                self.status = "已从公共库删除，本地图片和别人已下载的副本保留。"
            }
        }
    }
    private func request(_ packet: GalleryMessage, priority: Bool = false, completion: @escaping (Result<GalleryMessage, Error>) -> Void) {
        guard endpoint != nil else { completion(.failure(GalleryRequest.problem("请先开启服务器联机。"))); return }
        if priority { queue.insert((packet, completion), at: 0) } else { queue.append((packet, completion)) }
        pump()
    }
    private func pump() {
        guard active == nil, let endpoint, !queue.isEmpty else { return }
        let (packet, completion) = queue.removeFirst(), version = generation
        let request = GalleryRequest(endpoint: endpoint, packet: packet) { [weak self] result in
            guard let self, self.generation == version else { return }
            self.active = nil; completion(result)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.22) { [weak self] in self?.pump() }
        }
        active = request; request.start()
    }
}
