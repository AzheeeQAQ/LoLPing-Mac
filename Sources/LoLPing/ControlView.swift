import SwiftUI
import AppKit
import PingCore

private enum Palette {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.080)
    static let card = Color(red: 0.065, green: 0.090, blue: 0.120)
    static let gold = Color(red: 0.83, green: 0.70, blue: 0.44)
    static let secondary = Color(red: 0.59, green: 0.65, blue: 0.71)
}

struct ControlView: View {
    @ObservedObject var model: AppModel
    private enum LANField: Hashable { case nickname, room }
    @FocusState private var focusedField: LANField?
    @State private var editingShortcut = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                settingsCard
                RelayControlView(model: model, relay: model.relay)
                lanCard
                previewCard
                footer
            }.padding(26)
        }
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .tint(Palette.gold)
        .frame(minWidth: 610, minHeight: 620)
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "location.north.circle")
                .font(.system(size: 38, weight: .light)).foregroundStyle(Palette.gold)
                .frame(width: 54, height: 54)
                .background(Palette.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text("LoLPing").font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("把信号，带到桌面。").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Text("MAC EDITION").font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(Palette.gold)
        }
    }
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.isEnabled ? Color.green : (model.awaitingPermission ? Palette.gold : Palette.secondary))
                    .frame(width: 7, height: 7)
                Text("启用 Ping").font(.system(size: 17, weight: .semibold))
                Text(model.isEnabled ? "已开启" : (model.awaitingPermission ? "等待授权" : "已关闭"))
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Spacer()
                Toggle("启用 Ping", isOn: Binding(get: { model.isEnabled || model.awaitingPermission }, set: { model.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("启用 Ping")
            }
            Text(model.message).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("pingStatus")
            if model.awaitingPermission {
                HStack(spacing: 10) {
                    Button("打开辅助功能设置") { model.openAccessibility() }.buttonStyle(.borderedProminent)
                    Button("已授权，重新检查") { model.checkPermission() }.buttonStyle(.bordered)
                }.controlSize(.small)
                Text("仅监听操作所需按键，不读取或保存输入内容。授权后会自动开启。")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
        }.padding(16).card()
    }
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("触发组合键", systemImage: "keyboard").font(.system(size: 12))
                Spacer()
                Text(model.chord.symbols).font(.system(size: 14, weight: .medium)).accessibilityLabel("当前组合键 \(model.chord.symbols)")
                Button("自定义…") { editingShortcut = true }.buttonStyle(.bordered).controlSize(.small)
            }
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("音量", systemImage: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                        Spacer(); Text("\(Int(model.volume*100))%")
                    }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Slider(value: $model.volume, in: 0...1).accessibilityLabel("音量")
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("效果大小", systemImage: "arrow.up.left.and.arrow.down.right")
                        Spacer(); Text("\(Int(model.scale*100))%")
                    }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    Slider(value: $model.scale, in: 0.75...1.5, step: 0.05).accessibilityLabel("效果大小")
                }
            }
            Text("按住 0.18 秒 → 移动选择 → 松开发送　 ·　 Esc / 右键取消")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary)
        }.padding(16).card()
            .sheet(isPresented: $editingShortcut) { ShortcutEditor(model: model) }
    }
    private var lanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(lanDotColor).frame(width: 7, height: 7)
                Text("局域网联机").font(.system(size: 14, weight: .semibold))
                Text("和同一 Wi-Fi 的朋友互发信号").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Toggle("开启局域网联机", isOn: Binding(get: { model.lanEnabled }, set: { model.commitLANDrafts(); model.lanEnabled = $0 }))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("开启局域网联机")
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("昵称").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    TextField("朋友看到的名字", text: $model.lanNicknameDraft)
                        .textFieldStyle(.roundedBorder).focused($focusedField, equals: .nickname)
                        .onSubmit { model.commitLANDrafts() }.accessibilityLabel("昵称")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("房间码").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    TextField("4-8 位数字/字母，和朋友填一样的", text: $model.lanRoomDraft)
                        .textFieldStyle(.roundedBorder).focused($focusedField, equals: .room)
                        .onSubmit { model.commitLANDrafts() }.accessibilityLabel("房间码")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: model.lanStatus.problem == nil ? "person.2" : "exclamationmark.triangle")
                Text(model.lanStatusText).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("lanStatus")
            }.font(.system(size: 11)).foregroundStyle(model.lanStatus.problem == nil ? Palette.secondary : Palette.gold)
            HStack(spacing: 14) {
                Toggle("静音队友", isOn: $model.lanMuteTeammates).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                if !model.lanNotice.isEmpty {
                    Text(model.lanNotice).font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Button("发送测试信号") { model.commitLANDrafts(); model.sendTestSignal() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.lanEnabled)
            }
            Text("需要在同一个 Wi-Fi；访客网/校园网可能互相看不到，可试手机热点。只接收不需要辅助功能权限。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).card()
        .onChange(of: focusedField) { _ in model.commitLANDrafts() }
    }
    private var lanDotColor: Color {
        guard model.lanEnabled else { return Palette.secondary }
        if model.lanStatus.problem != nil { return Palette.gold }
        return model.lanPeers.online.isEmpty ? Palette.secondary : Color.green
    }
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("信号试用").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("仅在此区域预览 · 无需授权").font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Palette.background)
                PreviewGrid().stroke(Palette.gold.opacity(0.06), lineWidth: 0.5)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if model.previewVisible {
                    EffectPreview(kind: model.previewKind, scale: model.scale, token: model.previewToken)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "cursorarrow.rays").font(.system(size: 23, weight: .light)).foregroundStyle(Palette.gold.opacity(0.65))
                        Text("点选下方信号，感受一下").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    }
                }
                VStack { Spacer(); HStack { Spacer(); Text(model.previewVisible ? model.previewKind.title : "")
                    .font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(10) } }
            }.frame(height: max(120, 120*model.scale)).clipped()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(PingKind.allCases) { kind in
                    Button { model.preview(kind) } label: {
                        HStack(spacing: 9) {
                            if let icon = Assets.icon(kind) { Image(nsImage: icon).resizable().frame(width: 25, height: 25) }
                            Text(kind.title).font(.system(size: 11, weight: .medium))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 12).frame(height: 42)
                        .background(model.previewKind == kind && model.previewVisible ? Color(nsColor: kind.tint).opacity(0.14) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.05), lineWidth: 1))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("预览\(kind.title)")
                }
            }
        }.padding(16).card()
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("关闭窗口后仍在菜单栏运行").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Spacer()
                Menu("权限帮助") {
                    Button("辅助功能设置") { model.openAccessibility() }
                    Button("输入监控设置（按系统要求）") { model.openInputMonitoring() }
                }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                Button("退出软件") { NSApp.terminate(nil) }.buttonStyle(.bordered).controlSize(.small)
            }
            Text("独立桌面工具，非 Riot 官方产品。游戏素材归 Riot Games 所有；社区音效尚未核实为官方原声。")
                .font(.system(size: 9)).foregroundStyle(Palette.secondary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RelayControlView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var relay: RelayClient
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "globe").foregroundStyle(Palette.gold)
                Text("服务器联机").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("不同网络也能互发信号").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                Toggle("开启服务器联机", isOn: $model.relayEnabled)
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("开启服务器联机")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("服务器地址").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                TextField("wss://ping.example.com/ws", text: $relay.serverAddress)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("服务器地址").disabled(relay.isActive)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("昵称").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    TextField("朋友看到的名字", text: $relay.displayName)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("服务器联机昵称")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("房间码").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                    TextField("朋友分享的 12 位房间码", text: $relay.roomInput)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("服务器房间码")
                }
            }.disabled(relay.isActive)
            HStack(spacing: 10) {
                Button("创建房间") { model.createRelayRoom() }.buttonStyle(.borderedProminent).disabled(!model.relayEnabled || relay.isActive)
                Button("加入房间") { model.joinRelayRoom() }.buttonStyle(.bordered).disabled(!model.relayEnabled || relay.isActive)
                if !relay.room.isEmpty {
                    Button("复制房间码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(relay.formattedRoom, forType: .string)
                    }.buttonStyle(.bordered)
                }
                Spacer()
                Button("离开房间") { model.leaveRelayRoom() }.buttonStyle(.bordered).disabled(!relay.isActive)
            }.controlSize(.small)
            HStack(spacing: 6) {
                Circle().fill(relay.state == .connected ? Color.green : Palette.secondary).frame(width: 7, height: 7)
                Text(model.relayEnabled ? relay.status : "未开启 · 打开开关后创建或加入房间")
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("relayStatus")
            }.font(.system(size: 11)).foregroundStyle(Palette.secondary)
            HStack(spacing: 12) {
                Toggle("接收朋友信号", isOn: $relay.receiveEnabled).toggleStyle(.checkbox)
                Toggle("静音朋友", isOn: $relay.muteTeammates).toggleStyle(.checkbox)
                Spacer()
                Button("发送测试信号") { model.sendRelayTest() }.buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.relayEnabled || !relay.canSend).accessibilityLabel("发送服务器测试信号")
            }.font(.system(size: 11))
            Text("两人填写同一服务器地址，一人创建房间，另一人输入房间码加入。朋友的信号显示在主屏幕中央；只接收无需辅助功能权限。服务器联机和局域网联机切换使用。")
                .font(.system(size: 10)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).card()
    }
}

private extension View {
    func card() -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.gold.opacity(0.12), lineWidth: 1))
    }
}

private struct PreviewGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: CGFloat(0), through: rect.width, by: 24) {
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
        }
        for y in stride(from: CGFloat(0), through: rect.height, by: 24) {
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return path
    }
}

private struct EffectPreview: NSViewRepresentable {
    let kind: PingKind
    let scale: Double
    let token: UUID
    final class Coordinator { var token: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.token != token else { return }
        context.coordinator.token = token
        view.subviews.forEach { ($0 as? PingEffectView)?.stop(); $0.removeFromSuperview() }
        let effect = PingEffectView(frame: view.bounds, kind: kind, scale: CGFloat(scale))
        effect.autoresizingMask = [.width, .height]
        view.addSubview(effect)
        DispatchQueue.main.async { [weak effect] in effect?.start() }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        nsView.subviews.forEach { ($0 as? PingEffectView)?.stop() }
    }
}
