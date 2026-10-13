import SwiftUI
import PingCore

struct GalleryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: EmoteLibrary
    @ObservedObject var gallery: GalleryClient
    @ObservedObject var relay: RelayClient
    let slot: Int
    @Environment(\.dismiss) private var dismiss
    @State private var uploadID = ""
    @State private var search = ""
    @State private var savingID = ""
    private var visibleItems: [GalleryItem] {
        gallery.items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.uploader.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("服务器公共图片库", systemImage: "globe").font(.title3.weight(.semibold))
                Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("上传后，所有连接此服务器的人都能看到和下载。只上传你主动选择的图片。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("放入「\(WheelLayout.positions[slot])」").font(.system(size: 12, weight: .medium))
                Spacer(); Text("\(gallery.items.count) 张").foregroundStyle(.secondary)
                Button(gallery.refreshing ? "正在刷新…" : "刷新公共库") { configure(); gallery.refresh() }
                    .disabled(!model.relayEnabled || gallery.refreshing)
            }
            HStack {
                Picker("我的图片", selection: $uploadID) {
                    Text("选择要分享的图片").tag("")
                    ForEach(library.items) { Text($0.name).tag($0.id) }
                }.accessibilityLabel("选择上传的我的图片")
                Button("上传到公共库") {
                    configure()
                    if let payload = library.payload(uploadID) { gallery.upload(payload, uploader: relay.displayName) }
                }.disabled(!model.relayEnabled || uploadID.isEmpty || gallery.mutating)
            }
            if library.items.isEmpty { Text("先在轮盘中添加自己的图片，再选择上传。44 张内置表情已随应用提供。")
                .font(.system(size: 11)).foregroundStyle(.secondary) }
            TextField("搜索图片名称或上传昵称", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("搜索公共图片")
            ScrollView {
                if visibleItems.isEmpty {
                    Text(gallery.refreshing ? "正在加载…" : (search.isEmpty ? "公共库还没有图片。上传一张后，其他用户就能使用。" : "没有匹配的图片。"))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 80)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(visibleItems) { item in
                        VStack(spacing: 6) {
                            Group {
                                if let image = gallery.image(item.id) { Image(nsImage: image).resizable().scaledToFit() }
                                else { Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(.secondary) }
                            }.frame(width: 72, height: 72)
                            Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(2).frame(height: 30)
                            Text("上传：\(item.uploader)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            Button(savingID == item.id ? "正在保存…" : "保存并放入格子") {
                                savingID = item.id
                                gallery.load(item.id) { payload in
                                    savingID = ""
                                    if let payload { library.importShared(payload, into: slot) }
                                }
                            }.controlSize(.small).disabled(!model.relayEnabled || !savingID.isEmpty)
                                .accessibilityLabel("保存 \(item.name) 并放入\(WheelLayout.positions[slot])")
                            if gallery.canDelete(item.id) {
                                Button("从公共库删除", role: .destructive) { gallery.remove(item.id) }
                                    .controlSize(.mini).disabled(gallery.mutating || !model.relayEnabled)
                                    .accessibilityLabel("从公共库删除 \(item.name)")
                            }
                        }.frame(maxWidth: .infinity).padding(10)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .onAppear { gallery.load(item.id) }
                    }
                }
            }.frame(minHeight: 260, maxHeight: .infinity)
            Text(gallery.status).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !library.notice.isEmpty { Text(library.notice).font(.system(size: 11)).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true) }
            Text("图片长期保存在服务器。保存到本机后可离线使用；从公共库删除不会移除别人已保存的副本。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 610, height: 610)
            .background(Color(red: 0.065, green: 0.090, blue: 0.120)).preferredColorScheme(.dark)
            .onAppear { configure(); if model.relayEnabled { gallery.refresh() } }
            .onChange(of: relay.serverAddress) { _ in configure(); if model.relayEnabled { gallery.refresh() } }
            .onChange(of: model.relayEnabled) { enabled in if enabled { configure(); gallery.refresh() } else { gallery.disconnect() } }
    }
    private func configure() { if model.relayEnabled { gallery.configure(relay.serverAddress) } }
}
