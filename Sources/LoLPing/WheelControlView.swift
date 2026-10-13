import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PingCore

struct WheelControlView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: EmoteLibrary
    @State private var selectedSlot = 0
    @State private var showingGallery = false
    @State private var category = "全部"
    @State private var search = ""
    @State private var renaming: CustomEmote?
    @State private var draftName = ""
    @State private var dropTargeted = false
    private var content: WheelContent { library.wheel[selectedSlot] }
    private var choices: [WheelContent] {
        var result: [WheelContent] = []
        if category == "全部" || category == "信号" { result += PingKind.allCases.map(WheelContent.ping) }
        if category == "全部" || category == "内置表情" { result += library.bundled.map { .emote($0.id) } }
        if category == "全部" || category == "我的图片" { result += library.items.map { .emote($0.id) } }
        return result.filter { item in
            if search.isEmpty { return true }
            if library.name(item).localizedCaseInsensitiveContains(search) { return true }
            if case .emote(let id) = item, let entry = BundledEmotes.byID[id] {
                return entry.nameEnglish.localizedCaseInsensitiveContains(search) || entry.slug.localizedCaseInsensitiveContains(search)
            }
            return false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("轮盘内容", systemImage: "circle.grid.cross").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(library.bundled.count) 张内置 · \(library.items.count) / 24 自定义").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("信号和表情共用一个轮盘。先点格子，再点下方内容替换；也可以拖到格子上。更改自动保存。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                WheelEditor(library: library, selectedSlot: $selectedSlot)
                VStack(alignment: .leading, spacing: 11) {
                    Text("正在替换 · \(WheelLayout.positions[selectedSlot])").font(.system(size: 12, weight: .semibold))
                    WheelThumbnail(library: library, content: content, side: 76)
                    Text(library.name(content)).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("试用") { model.previewWheelContent(content) }.disabled(content == .empty)
                        Button("发送") { model.sendWheelContent(content) }.disabled(content == .empty)
                    }.controlSize(.small)
                    Button("清空这个格子") { library.setSlot(.empty, at: selectedSlot) }.controlSize(.small)
                    Spacer(minLength: 3)
                    Button("恢复默认轮盘") { library.resetWheel() }.controlSize(.small)
                    Text("留空的格子不会发送。中心格也可以替换。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 280)
            }
            HStack {
                Text("替换「\(WheelLayout.positions[selectedSlot])」").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("公共图片库…") { showingGallery = true }.controlSize(.small).disabled(!model.relayEnabled)
                    .help("开启服务器联机后，浏览与分享公共图片，无需加入房间。")
                Button("添加图片…") { library.chooseImages(forSlot: selectedSlot); category = "我的图片" }.controlSize(.small)
            }
            Picker("内容类别", selection: $category) {
                ForEach(["全部", "信号", "内置表情", "我的图片"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).accessibilityLabel("轮盘内容类别")
            TextField("搜索名称", text: $search).textFieldStyle(.roundedBorder).accessibilityLabel("搜索轮盘内容")
            ScrollView {
                if choices.isEmpty {
                    Text(search.isEmpty ? "还没有自定义图片，点击添加或拖入图片。" : "没有匹配的内容")
                        .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 60)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(choices) { item in
                        Button { library.setSlot(item, at: selectedSlot) } label: {
                            VStack(spacing: 4) {
                                WheelThumbnail(library: library, content: item, side: 42)
                                Text(library.name(item)).font(.system(size: 9)).lineLimit(2).frame(height: 25)
                            }.frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(content == item ? Color.yellow.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(content == item ? Color.yellow.opacity(0.6) : .clear))
                        }.buttonStyle(.plain).help(library.name(item))
                            .accessibilityLabel("替换为 \(library.name(item))")
                            .onDrag { NSItemProvider(object: item.rawValue as NSString) }
                            .contextMenu {
                                Button("试用") { model.previewWheelContent(item) }
                                if case .emote(let id) = item, let custom = library.items.first(where: { $0.id == id }) {
                                    Button("上传到公共库") {
                                        model.gallery.configure(model.relay.serverAddress)
                                        if let payload = library.payload(id) { model.gallery.upload(payload, uploader: model.relay.displayName) }
                                        showingGallery = true
                                    }.disabled(!model.relayEnabled)
                                    Button("重命名…") { renaming = custom; draftName = custom.name }
                                    Button("删除图片", role: .destructive) { library.remove(id) }
                                }
                            }
                    }
                }.padding(1)
            }.frame(height: 246).accessibilityLabel("可替换的信号和图片")
            Text("内置表情来自 darrenprx/lolPing，素材 © Riot Games。自己的图片支持 PNG / JPG / GIF / WebP，单张不超过 8 MB，动态图使用首帧。朋友无需导入即可看到发送的图片。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !library.notice.isEmpty { Text(library.notice).font(.system(size: 11)).foregroundStyle(Color(red: 0.83, green: 0.70, blue: 0.44)).textSelection(.enabled) }
        }.padding(16)
            .background(Color(red: 0.065, green: 0.090, blue: 0.120), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(dropTargeted ? Color.yellow : Color.white.opacity(0.07), lineWidth: 1))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                if WheelDrop.importFiles(providers, library: library, slot: selectedSlot) { category = "我的图片"; return true }
                return false
            }
            .sheet(isPresented: $showingGallery) {
                GalleryView(model: model, library: library, gallery: model.gallery, relay: model.relay, slot: selectedSlot)
            }
            .sheet(item: $renaming) { _ in
                VStack(alignment: .leading, spacing: 18) {
                    Text("图片名称").font(.headline)
                    TextField("名称（最多 24 字符）", text: $draftName).textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer(); Button("取消") { renaming = nil }
                        Button("保存") { if let item = renaming { library.rename(item.id, to: draftName) }; renaming = nil }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 330).preferredColorScheme(.dark)
            }
    }
}
