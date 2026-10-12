import AppKit
import SwiftUI
import PingCore

struct ShortcutEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var modifiers: Modifiers
    @State private var keyCode: Int

    init(model: AppModel) {
        self.model = model
        _modifiers = State(initialValue: model.chord.modifiers)
        _keyCode = State(initialValue: model.chord.keyCode ?? -1)
    }
    private var selection: TriggerChord? {
        TriggerChord(modifiers: modifiers, keyCode: keyCode == -1 ? nil : keyCode)
    }
    private func binding(_ modifier: Modifiers) -> Binding<Bool> {
        Binding(get: { modifiers.contains(modifier) }, set: {
            if $0 { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("自定义组合键").font(.system(size: 19, weight: .semibold))
            Text("选择修饰键，可再搭配一个按键。设置期间暂停全局快捷键。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Toggle("⌃ Control", isOn: binding(.control))
                Toggle("⌥ Option", isOn: binding(.option))
                Toggle("⇧ Shift", isOn: binding(.shift))
                Toggle("⌘ Command", isOn: binding(.command))
            }.toggleStyle(.checkbox)
            Picker("搭配按键", selection: $keyCode) {
                Text("只使用修饰键").tag(-1)
                ForEach(TriggerChord.availableKeys.indices, id: \.self) { index in
                    Text(TriggerChord.availableKeys[index].title).tag(TriggerChord.availableKeys[index].code)
                }
            }.frame(width: 290).accessibilityLabel("组合键搭配按键")
            Text(selection?.symbols ?? "请选择有效的组合键")
                .font(.system(size: 24, weight: .medium)).frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            Text(selection == nil
                 ? "只使用修饰键时至少选择两个；搭配普通按键时至少选择一个修饰键。"
                 : (keyCode == -1 ? "同时按住所选修饰键，移动选择，松开发送。" : "先按住修饰键，再按住搭配按键，移动选择，松开任一键发送。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Esc 或右键取消信号。建议避开游戏和系统已有的快捷键；F 键可能需配合 Fn。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("恢复默认") { modifiers = TriggerChord.controlOptionCommand.modifiers; keyCode = -1 }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if let selection { model.chord = selection; dismiss() }
                }.buttonStyle(.borderedProminent).disabled(selection == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 550)
            .background(Color(red: 0.065, green: 0.090, blue: 0.120))
            .preferredColorScheme(.dark).tint(Color(red: 0.83, green: 0.70, blue: 0.44))
            .onAppear { model.beginShortcutEditing() }
            .onDisappear { model.endShortcutEditing() }
    }
}
