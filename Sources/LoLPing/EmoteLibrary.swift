import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PingCore

struct CustomEmote: Codable, Identifiable {
    let id: String
    var name: String
}

final class EmoteLibrary: ObservableObject {
    struct Manifest: Codable { var items: [CustomEmote]; var slots: [String]; var wheel: [String]? }
    @Published private(set) var items: [CustomEmote] = []
    @Published private(set) var wheel = WheelLayout.defaults
    var bundled: [CustomEmote] { BundledEmotes.items }
    var allItems: [CustomEmote] { bundled + items }
    // Read-only compatibility projection for migrating the previous separate wheel.
    var slots: [String] { wheel.prefix(8).map { if case .emote(let id) = $0 { return id }; return "" } }
    func isKnown(_ id: String) -> Bool { BundledEmotes.byID[id] != nil || items.contains(where: { $0.id == id }) }
    func name(_ content: WheelContent) -> String {
        switch content {
        case .ping(let kind): return kind.title
        case .emote(let id): return allItems.first(where: { $0.id == id })?.name ?? "图片缺失"
        case .empty: return "留空"
        }
    }
    @Published private(set) var notice = ""
    private let directory: URL
    private var images: [String: NSImage] = [:]
    init(directory: URL? = nil) {
        // Preserve the released app's existing data path. A differently named
        // bundle (such as a development build) gets its own image preferences.
        let bundleID = Bundle.main.bundleIdentifier ?? "local.allentu.LoLPing"
        let folder = bundleID == "local.allentu.LoLPing" ? "LoLPing" : bundleID
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder+"/Emotes", isDirectory: true)
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("library.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            var seen = Set<String>()
            items = manifest.items.prefix(24).filter { entry in
                guard seen.insert(entry.id).inserted, entry.name == RelayProtocol.displayName(entry.name),
                      let payload = payload(id: entry.id, name: entry.name), Self.decode(payload) != nil else { return false }
                return true
            }
            if let saved = manifest.wheel, saved.count == 9 {
                wheel = saved.map { raw in
                    guard let content = WheelContent(rawValue: raw) else { return .empty }
                    if case .emote(let id) = content, !isKnown(id) { return .empty }
                    return content
                }
            } else if manifest.slots.count == 8 {
                // Preserve prior custom image positions while filling the other
                // positions with the original ping layout. Do this only once.
                for (index, id) in manifest.slots.enumerated() where isKnown(id) { wheel[index] = .emote(id) }
            }
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func decode(_ payload: EmotePayload) -> NSImage? {
        guard payload.isValid, Self.hash(payload.png) == payload.id,
              let source = CGImageSourceCreateWithData(payload.png as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width <= EmotePayload.maxSide, image.height <= EmotePayload.maxSide else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }
    private func file(_ id: String) -> URL? {
        guard id.count == 64, id.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return directory.appendingPathComponent(id+".png")
    }
    private func payload(id: String, name: String) -> EmotePayload? {
        guard let url = file(id), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= EmotePayload.maxBytes, let data = try? Data(contentsOf: url) else { return nil }
        return EmotePayload(id: id, name: name, png: data)
    }
    func payload(_ id: String) -> EmotePayload? {
        if let bundled = BundledEmotes.payload(id) { return bundled }
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return payload(id: id, name: item.name)
    }
    func image(_ id: String) -> NSImage? {
        if let cached = images[id] { return cached }
        guard let payload = payload(id), let image = Self.decode(payload) else { return nil }
        images[id] = image; return image
    }
    func assign(_ id: String, to slot: Int) { setSlot(id.isEmpty ? .empty : .emote(id), at: slot) }
    @discardableResult func setSlot(_ content: WheelContent, at slot: Int) -> Bool {
        guard wheel.indices.contains(slot) else { return false }
        if case .emote(let id) = content, !isKnown(id) { return false }
        let previous = wheel; wheel[slot] = content
        do { try save(); notice = "已替换「\(WheelLayout.positions[slot])」为「\(name(content))」，已自动保存。"; return true }
        catch { wheel = previous; notice = "保存轮盘失败：\(error.localizedDescription)"; return false }
    }
    func resetWheel() {
        let previous = wheel; wheel = WheelLayout.defaults
        do { try save(); notice = "已恢复默认信号轮盘，图片库仍可继续使用。" }
        catch { wheel = previous; notice = "保存轮盘失败：\(error.localizedDescription)" }
    }
    func rename(_ id: String, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items; items[index].name = RelayProtocol.displayName(name)
        do { try save() } catch { items = old; notice = "保存名称失败：\(error.localizedDescription)" }
    }
    func remove(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        let oldItems = items, oldWheel = wheel
        items.removeAll { $0.id == id }; wheel = wheel.map { $0 == .emote(id) ? .empty : $0 }
        do { try save(); if let path = file(id) { try? FileManager.default.removeItem(at: path) }; images[id] = nil; notice = "已删除表情" }
        catch { items = oldItems; wheel = oldWheel; notice = "删除失败：\(error.localizedDescription)" }
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Manifest(items: items, slots: slots, wheel: wheel.map(\.rawValue))).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
    func chooseImages(forSlot slot: Int? = nil) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, UTType("org.webmproject.webp") ?? .image]
        panel.message = "添加自定义表情（最多 24 张）；GIF / WebP 使用首帧"
        panel.begin { [weak self] result in if result == .OK { self?.importImages(panel.urls, forSlot: slot) } }
    }
    func importImages(_ urls: [URL], forSlot slot: Int? = nil) {
        var added = 0, errors: [String] = [], firstID: String?
        for url in urls.prefix(24) {
            do { try importImage(url); added += 1; if firstID == nil { firstID = items.last?.id } }
            catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        var assigned = false
        if let slot, let firstID {
            assigned = setSlot(.emote(firstID), at: slot)
            if !assigned { errors.append(notice) }
        }
        notice = ([added > 0 ? "已添加 \(added) 张图片。"+(assigned ? "第一张已放入选中格，已自动保存。" : "点击轮盘格子，再选图片即可替换。") : ""] + errors).filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func importImage(_ url: URL) throws {
        func problem(_ text: String) -> NSError { NSError(domain: "EmoteImport", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard items.count < 24 else { throw problem("最多保存 24 张，请先删除不需要的表情") }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 8_388_608 else { throw problem("图片需小于 8 MB") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192 else { throw problem("请选择有效的 PNG、JPG、GIF 或 WebP 图片（最长边不超过 8192 像素）") }
        var prepared: Data?
        for side in [160, 128, 96, 64] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { break }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            if CGImageDestinationFinalize(destination), png.length <= EmotePayload.maxBytes { prepared = png as Data; break }
        }
        guard let png = prepared else { throw problem("无法处理这张图片，请换一张") }
        let id = Self.hash(png), name = RelayProtocol.displayName(url.deletingPathExtension().lastPathComponent)
        guard !isKnown(id) else { throw problem("这张表情已经添加过了") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: file(id)!, options: .atomic)
        let oldItems = items
        items.append(CustomEmote(id: id, name: name))
        do { try save() } catch { items = oldItems; try? FileManager.default.removeItem(at: file(id)!); throw error }
    }
}
