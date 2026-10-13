import Foundation
import PingCore

enum BundledEmotes {
    struct Entry: Decodable {
        let id: String
        let name: String
        let nameEnglish: String
        let slug: String
        let file: String
    }
    private struct Catalog: Decodable { let items: [Entry] }
    static let root = Assets.root.appendingPathComponent("Emotes", isDirectory: true)
    static let entries: [Entry] = {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("catalog.json")),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        var seen = Set<String>()
        return catalog.items.filter {
            WheelContent(rawValue: "emote:"+$0.id) != nil && seen.insert($0.id).inserted &&
                !$0.slug.isEmpty && $0.slug.count <= 40 && $0.slug.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789_".contains($0) }) &&
                $0.file == $0.slug+".png" && $0.name == RelayProtocol.displayName($0.name)
        }
    }()
    static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    static let items = entries.map { CustomEmote(id: $0.id, name: $0.name) }
    static func payload(_ id: String) -> EmotePayload? {
        guard let item = byID[id], let data = try? Data(contentsOf: root.appendingPathComponent(item.file)),
              data.count <= EmotePayload.maxBytes else { return nil }
        return EmotePayload(id: id, name: item.name, png: data)
    }
    static var validationFailures: [String] {
        var failures = entries.count == 44 ? [] : ["内置表情目录不完整（应有 44 张）"]
        for item in entries where payload(item.id).flatMap(EmoteLibrary.decode) == nil { failures.append("内置表情缺失或损坏："+item.slug) }
        return failures
    }
}
