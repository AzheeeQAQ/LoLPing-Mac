import AppKit
import SwiftUI
import PingCore

struct ShortcutEditor: View {
    @ObservedObject var model: AppModel
    let forEmotes: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = ShortcutRecorder()
    @State private var resetConflict = false
    init(model: AppModel, forEmotes: Bool = false) { self.model = model; self.forEmotes = forEmotes }
    private var chord: TriggerChord { forEmotes ? model.emoteChord : model.chord }
    private func save(_ selection: TriggerChord) -> Bool {
        guard !selection.conflicts(with: forEmotes ? model.chord : model.emoteChord) else { return false }
        if forEmotes { model.emoteChord = selection } else { model.chord = selection }
        return true
    }
    private func record() { resetConflict = false; recorder.start(accept: save) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(forEmotes ? "表情组合键" : "自定义组合键").font(.system(size: 19, weight: .semibold))
            Text("直接按下想用的按键，全部松开后自动记住。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(recorder.isRecording ? recorder.display : chord.symbols)
                .font(.system(size: 24, weight: .medium)).frame(maxWidth: .infinity, minHeight: 64)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("录入组合键 \(recorder.isRecording ? recorder.display : chord.symbols)")
            Text(resetConflict ? "默认组合键和另一套快捷键重叠，请先修改另一套。" : recorder.message)
                .font(.system(size: 12)).foregroundStyle(resetConflict ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("支持单键、多个按键及修饰键组合，包含 F 键、小键盘、Esc、Fn 和 Caps Lock。录入期间暂停全局信号。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("选中的按键会用于全局信号；建议避开常用打字键和系统快捷键。系统独占或未传递给应用的按键无法录入。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("恢复默认") {
                    recorder.stop(); resetConflict = !save(forEmotes ? .controlOptionShift : .controlOptionCommand)
                }.buttonStyle(.bordered)
                Button("重新录入") { record() }.buttonStyle(.bordered)
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }.padding(26).frame(width: 500)
            .background(Color(red: 0.065, green: 0.090, blue: 0.120))
            .preferredColorScheme(.dark).tint(Color(red: 0.83, green: 0.70, blue: 0.44))
            .onAppear { model.beginShortcutEditing(); record() }
            .onDisappear { recorder.stop(); model.endShortcutEditing() }
    }
}
