import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PingCore

struct WheelThumbnail: View {
    @ObservedObject var library: EmoteLibrary
    let content: WheelContent
    let side: CGFloat
    var body: some View {
        Group {
            switch content {
            case .ping(let kind):
                if let image = Assets.icon(kind) { Image(nsImage: image).resizable().scaledToFit().padding(side*0.14) }
            case .emote(let id):
                if let image = library.image(id) { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            case .empty: Image(systemName: "plus").font(.system(size: side*0.35)).foregroundStyle(.secondary)
            }
        }.frame(width: side, height: side)
    }
}

private struct WheelSector: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), outer = rect.width*0.48, inner = rect.width*0.22
        let start = Double(index)*45-112.5, end = start+45
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        p.closeSubpath()
        return p
    }
}

/// Accessible, clickable sectors, using exactly the same clockwise position
/// order as the live gesture wheel. Text drags carry validated slot content.
struct WheelEditor: View {
    @ObservedObject var library: EmoteLibrary
    @Binding var selectedSlot: Int
    private let gold = Color(red: 0.83, green: 0.70, blue: 0.44)
    private let side: CGFloat = 318
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let theta = CGFloat(index)*(.pi/4)-(.pi/2)
                Button { selectedSlot = index } label: {
                    ZStack {
                        WheelSector(index: index).fill(selectedSlot == index ? gold.opacity(0.20) : Color.white.opacity(0.035))
                        WheelSector(index: index).stroke(selectedSlot == index ? gold : Color.white.opacity(0.13), lineWidth: selectedSlot == index ? 1.8 : 0.7)
                        VStack(spacing: 3) {
                            WheelThumbnail(library: library, content: library.wheel[index], side: 37)
                            Text(library.name(library.wheel[index])).font(.system(size: 9)).lineLimit(1).frame(width: 74)
                        }.position(x: side/2+cos(theta)*side*0.345, y: side/2+sin(theta)*side*0.345)
                    }.frame(width: side, height: side).contentShape(WheelSector(index: index))
                }.buttonStyle(.plain)
                    .accessibilityLabel("轮盘\(WheelLayout.positions[index])，当前\(library.name(library.wheel[index]))")
                    .accessibilityValue(selectedSlot == index ? "已选中" : "点击替换")
            }
            Button { selectedSlot = 8 } label: {
                VStack(spacing: 2) {
                    WheelThumbnail(library: library, content: library.wheel[8], side: 33)
                    Text("中心").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(width: side*0.44, height: side*0.44)
                    .background(selectedSlot == 8 ? gold.opacity(0.20) : Color(red: 0.065, green: 0.090, blue: 0.120), in: Circle())
                    .overlay(Circle().stroke(selectedSlot == 8 ? gold : gold.opacity(0.45), lineWidth: 1.5))
                    .contentShape(Circle())
            }.buttonStyle(.plain)
                .accessibilityLabel("轮盘中心，当前\(library.name(library.wheel[8]))")
                .accessibilityValue(selectedSlot == 8 ? "已选中" : "点击替换")
        }.frame(width: side, height: side)
            .onDrop(of: [UTType.utf8PlainText, UTType.fileURL], isTargeted: nil) { providers, location in
                guard let slot = WheelLayout.editorSlot(at: location, side: side) else { return false }
                return drop(providers, into: slot)
            }
    }
    private func drop(_ providers: [NSItemProvider], into slot: Int) -> Bool {
        if WheelDrop.importFiles(providers, library: library, slot: slot) { selectedSlot = slot; return true }
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let raw = value as? String, let content = WheelContent(rawValue: raw) else { return }
            DispatchQueue.main.async { selectedSlot = slot; library.setSlot(content, at: slot) }
        }
        return true
    }
}

enum WheelDrop {
    /// Keep original file order across asynchronous providers; the first valid
    /// image replaces the selected slot, while the others just enter the library.
    static func importFiles(_ providers: [NSItemProvider], library: EmoteLibrary, slot: Int) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }.prefix(24)
        guard !files.isEmpty else { return false }
        let group = DispatchGroup(), lock = NSLock()
        var urls: [Int: URL] = [:]
        for (index, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                lock.lock(); urls[index] = url; lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let ordered = urls.sorted { $0.key < $1.key }.map(\.value)
            library.importImages(ordered, forSlot: slot)
        }
        return true
    }
}
