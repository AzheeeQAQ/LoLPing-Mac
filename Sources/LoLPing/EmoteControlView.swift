import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PingCore

struct EmoteControlView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: EmoteLibrary
    @State private var editingShortcut = false
    @State private var renaming: CustomEmote?
    @State private var draftName = ""
    @State private var dropTargeted = false
    private let directions = ["↑ 上", "↗ 右上", "→ 右", "↘ 右下", "↓ 下", "↙ 左下", "← 左", "↖ 左上"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("自定义表情", systemImage: "face.smiling").font(.system(size: 15, weight: .semibold))
                Text("\(library.items.count) / 24").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("开启表情", isOn: $model.emoteEnabled).toggleStyle(.switch).labelsHidden().accessibilityLabel("开启表情")
            }
            HStack {
                Text("表情组合键").font(.system(size: 12))
                Spacer(); Text(model.emoteChord.symbols).font(.system(size: 14, weight: .medium))
                Button("自定义…") { editingShortcut = true }.controlSize(.small)
            }
            if model.emoteChord.conflicts(with: model.chord) { Text("表情快捷键与 Ping 重叠，请点击自定义修改。").font(.system(size: 11)).foregroundStyle(.orange) }
            Text("启用 Ping 后，按住表情组合键 → 移动选择 → 松开发送。轮盘中心和空格不发送；Esc / 右键取消。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(0..<8, id: \.self) { index in
                    VStack(spacing: 6) {
                        thumbnail(library.slots[index], side: 38)
                        Picker(directions[index], selection: Binding(get: { library.slots[index] }, set: {
                            model.cancelEffects(); library.assign($0, to: index)
                        })) {
                            Text("空格").tag("")
                            ForEach(library.items) { item in Text(item.name).tag(item.id) }
                        }.labelsHidden().accessibilityLabel("表情轮盘\(directions[index])")
                        Text(directions[index]).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(8).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack {
                Button("添加图片…") { library.chooseImages() }.buttonStyle(.borderedProminent)
                Text("也可将图片拖到这里").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            if !library.items.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(library.items) { item in
                        VStack(spacing: 6) {
                            Button { model.previewEmote(item.id) } label: { thumbnail(item.id, side: 52) }
                                .buttonStyle(.plain).accessibilityLabel("预览表情 \(item.name)")
                            Text(item.name).font(.system(size: 11)).lineLimit(1).help(item.name)
                            HStack(spacing: 5) {
                                Button("发送") { model.sendEmote(item.id) }.disabled(!model.emoteEnabled).controlSize(.mini)
                                Menu {
                                    Button("预览") { model.previewEmote(item.id) }
                                    Button("重命名…") { draftName = item.name; renaming = item }
                                    Button("删除表情", role: .destructive) { model.cancelEffects(); library.remove(item.id) }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                            }
                        }.padding(8).frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text("PNG / JPG / GIF / WebP · 单张不超过 8 MB · GIF / WebP 使用首帧。开启服务器或局域网联机后，朋友无需导入即可看到；双方使用 1.5.0 或更新版本。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !library.notice.isEmpty { Text(library.notice).font(.system(size: 11)).foregroundStyle(Color(red: 0.83, green: 0.70, blue: 0.44)).textSelection(.enabled) }
        }.padding(16)
            .background(Color(red: 0.065, green: 0.090, blue: 0.120), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(dropTargeted ? Color.yellow : Color.white.opacity(0.07), lineWidth: 1))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers.prefix(24) {
                    _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                        DispatchQueue.main.async { library.importImages([url]) }
                    }
                }
                return true
            }
            .sheet(isPresented: $editingShortcut) { ShortcutEditor(model: model, forEmotes: true) }
            .sheet(item: $renaming) { _ in
                VStack(alignment: .leading, spacing: 18) {
                    Text("表情名称").font(.headline)
                    TextField("名称（最多 24 字符）", text: $draftName).textFieldStyle(.roundedBorder)
                    HStack { Spacer(); Button("取消") { renaming = nil }; Button("保存") {
                        if let item = renaming { library.rename(item.id, to: draftName) }; renaming = nil
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 330).preferredColorScheme(.dark)
            }
    }
    @ViewBuilder private func thumbnail(_ id: String, side: CGFloat) -> some View {
        if let image = library.image(id) { Image(nsImage: image).resizable().scaledToFit().frame(width: side, height: side) }
        else { Image(systemName: "plus").foregroundStyle(.secondary).frame(width: side, height: side) }
    }
}
