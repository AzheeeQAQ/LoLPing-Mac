import AppKit
import Combine
import PingCore

final class AppModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var awaitingPermission = false
    @Published private(set) var message = "全局信号已关闭。你仍可在下方预览效果。"
    @Published var chord: TriggerChord {
        didSet { defaults.set(chord.rawValue, forKey: "triggerChord"); restartInputIfNeeded() }
    }
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: "volume") }
    }
    @Published var scale: Double {
        didSet { defaults.set(scale, forKey: "effectScale"); restartInputIfNeeded() }
    }
    @Published var relayEnabled: Bool {
        didSet {
            defaults.set(relayEnabled, forKey: "relayEnabled")
            if relayEnabled {
                if lanEnabled { lanEnabled = false }
            } else {
                relay.disconnect(); clearTeammateEffects()
            }
            onStateChange?()
        }
    }
    private var editingShortcut = false
    @Published private(set) var previewKind: PingKind = .missing
    @Published private(set) var previewToken = UUID()
    @Published private(set) var previewVisible = false
    // 局域网联机: receiving only depends on lanEnabled, never on Accessibility.
    @Published var lanEnabled: Bool {
        didSet {
            defaults.set(lanEnabled, forKey: "lanEnabled")
            if lanEnabled { relayEnabled = false }
            restartLAN()
        }
    }
    @Published var lanMuteTeammates: Bool {
        didSet { defaults.set(lanMuteTeammates, forKey: "lanMuteTeammates"); if lanMuteTeammates { teammateSound.stopAll() }; onStateChange?() }
    }
    @Published private(set) var lanNickname: String
    @Published private(set) var lanRoomCode: String
    // Text field drafts, committed on Return, focus or window loss, or after a
    // short pause in typing rather than per keystroke, so typing a room code
    // does not restart the network each time.
    @Published var lanNicknameDraft = "" {
        didSet { scheduleDraftCommit() }
    }
    @Published var lanRoomDraft = "" {
        didSet { scheduleDraftCommit() }
    }
    @Published private(set) var lanStatus: LANSession.Status = .stopped
    @Published private(set) var lanPeers = LANSession.Peers()
    @Published private(set) var lanNotice = ""
    var onStateChange: (() -> Void)?
    let defaults: UserDefaults
    let relay: RelayClient
    private var relayObservation: AnyCancellable?
    private let input = GlobalInput()
    private let overlay = OverlayController()
    private let sound = SoundPlayer()
    private let teammateSound = SoundPlayer()
    private let lan = LANSession()
    private var noticeCleanup: DispatchWorkItem?
    private var draftCommit: DispatchWorkItem?
    private var previewCleanup: DispatchWorkItem?
    private var permissionTimer: Timer?
    private var observations: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        relay = RelayClient(defaults: defaults)
        chord = TriggerChord(rawValue: defaults.string(forKey: "triggerChord") ?? "") ?? .controlOptionCommand
        volume = defaults.object(forKey: "volume") == nil ? 0.55 : min(max(defaults.double(forKey: "volume"), 0), 1)
        scale = defaults.object(forKey: "effectScale") == nil ? 1 : min(max(defaults.double(forKey: "effectScale"), 0.75), 1.5)
        lanEnabled = defaults.bool(forKey: "lanEnabled")
        relayEnabled = !defaults.bool(forKey: "lanEnabled") && defaults.bool(forKey: "relayEnabled")
        lanMuteTeammates = defaults.bool(forKey: "lanMuteTeammates")
        let savedName = LANProtocol.sanitizeName(defaults.string(forKey: "lanNickname") ?? "")
        lanNickname = savedName.isEmpty ? AppModel.defaultNickname : savedName
        lanRoomCode = LANProtocol.normalizeRoomCode(defaults.string(forKey: "lanRoomCode") ?? "")
        lanNicknameDraft = lanNickname; lanRoomDraft = lanRoomCode
        input.onAction = { [weak self] action in self?.handle(action) }
        input.onUnavailable = { [weak self] in
            self?.setEnabled(false)
            self?.message = "全局输入已暂停，请检查辅助功能权限后重新开启。"
        }
        lan.onStatus = { [weak self] status in self?.lanStatus = status; self?.onStateChange?() }
        lan.onPeers = { [weak self] peers in self?.lanPeers = peers; self?.onStateChange?() }
        lan.onReceive = { [weak self] message, playSound in self?.showTeammate(message, playSound: playSound) }
        relay.onPing = { [weak self] kind, name in self?.showRemotePing(kind, sender: name) }
        relay.onFailure = { [weak self] _ in self?.clearTeammateEffects() }
        relayObservation = relay.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.relay.isActive && !self.relay.receiveEnabled { self.clearTeammateEffects() }
                if self.relay.isActive && self.relay.muteTeammates { self.teammateSound.stopAll() }
                self.onStateChange?()
            }
        }
        let center = NotificationCenter.default
        observations.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.checkPermission() })
        observations.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelEffects(); self?.clearTeammateEffects()
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelEffects(); self?.clearTeammateEffects()
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.relay.reconnectAfterWake()
        })
        // Teammate pings are not ours to cancel on focus or Space changes; they expire on their own.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cancelEffects() })
        }
    }
    static var defaultNickname: String {
        let name = LANProtocol.sanitizeName(Host.current().localizedName ?? "")
        return name.isEmpty ? "玩家" : name
    }
    func restoreState() {
        if defaults.bool(forKey: "enabled") {
            if GlobalInput.isTrusted { setEnabled(true) }
            else { message = "上次已启用，但当前缺少辅助功能权限。开启开关可重新授权。" }
        }
        if !Assets.missingFiles.isEmpty { message = "素材缺失，请重新构建应用：" + Assets.missingFiles.joined(separator: "、") }
        restartLAN()
    }
    func setEnabled(_ value: Bool) {
        if !value {
            awaitingPermission = false
            permissionTimer?.invalidate(); permissionTimer = nil
            input.stop(); overlay.clear(); sound.stopAll(); stopPreview()
            isEnabled = false; defaults.set(false, forKey: "enabled")
            message = "全局信号已关闭。你仍可在下方预览效果。"
            onStateChange?()
            return
        }
        guard GlobalInput.isTrusted else {
            awaitingPermission = true
            message = "还差一步：在系统设置 → 隐私与安全性 → 辅助功能中开启 LoLPing。"
            GlobalInput.requestPermission()
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.checkPermission() }
            onStateChange?()
            return
        }
        do {
            if !editingShortcut { try input.start(chord: chord, scale: scale) }
            isEnabled = true; awaitingPermission = false
            permissionTimer?.invalidate(); permissionTimer = nil
            defaults.set(true, forKey: "enabled")
            message = "已就绪。按住 \(chord.symbols)，移动选择，松开发送。"
        } catch {
            isEnabled = false; awaitingPermission = false
            permissionTimer?.invalidate(); permissionTimer = nil
            defaults.set(false, forKey: "enabled")
            message = error.localizedDescription
        }
        onStateChange?()
    }
    func checkPermission() {
        if awaitingPermission && GlobalInput.isTrusted { setEnabled(true) }
        else if isEnabled && !GlobalInput.isTrusted {
            setEnabled(false); message = "辅助功能权限已关闭，请重新授权后开启 Ping。"
        }
    }
    func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    func preview(_ kind: PingKind) {
        previewCleanup?.cancel()
        previewKind = kind; previewToken = UUID(); previewVisible = true
        sound.play(kind, volume: volume)
        let cleanup = DispatchWorkItem { [weak self] in self?.previewVisible = false }
        previewCleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now()+2.1, execute: cleanup)
    }
    func stopPreview() {
        previewCleanup?.cancel(); previewCleanup = nil; previewVisible = false
    }
    /// Local wheel, pings and sounds only; teammate pings keep playing.
    func cancelEffects() { input.cancelCurrent(); overlay.clear(); sound.stopAll(); stopPreview() }
    func clearTeammateEffects() { overlay.clearTeammates(); teammateSound.stopAll() }
    func shutdown() {
        // Preserve the user's enabled preference across an intentional app quit.
        permissionTimer?.invalidate(); input.stop(); overlay.clear(); sound.stopAll(); stopPreview()
        lan.stop(); relay.disconnect(); clearTeammateEffects()
    }

    // MARK: 服务器联机

    func createRelayRoom() { guard relayEnabled else { return }; relay.createRoom() }
    func joinRelayRoom() { guard relayEnabled else { return }; relay.joinRoom() }
    func leaveRelayRoom() { relay.disconnect(); clearTeammateEffects() }
    func sendRelayTest() { guard relayEnabled else { return }; relay.sendPing(.generic) }
    private func showRemotePing(_ kind: PingKind, sender: String) {
        guard relayEnabled, relay.receiveEnabled, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let center = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        overlay.showPing(kind, at: center, scale: scale, label: sender, teammate: true)
        if !relay.muteTeammates { teammateSound.play(kind, volume: volume) }
    }

    // MARK: 局域网联机

    var lanStatusText: String {
        guard lanEnabled else { return "未开启" }
        guard !lanRoomCode.isEmpty else { return "填写房间码后开始联机" }
        if let problem = lanStatus.problem { return problem }
        if let online = onlineSummary(limit: 10) { return online }
        return lanStatus == .ready ? "等待队友加入…" : "正在启动…"
    }
    var lanMenuTitle: String {
        guard lanEnabled else { return "局域网：未开启" }
        guard !lanRoomCode.isEmpty else { return "局域网：未填写房间码" }
        return "局域网：房间 \(lanRoomCode) · \(lanPeers.online.count) 人在线" + (lanStatus.problem == nil ? "" : "（连接异常）")
    }
    /// Who is online, for the menu; nil when nobody is.
    var lanMenuPeers: String? {
        guard lanEnabled, !lanRoomCode.isEmpty else { return nil }
        return onlineSummary(limit: 6)
    }
    private func onlineSummary(limit: Int) -> String? {
        let names = lanPeers.online
        guard !names.isEmpty else { return nil }
        return "在线：" + names.prefix(limit).joined(separator: "、") + (names.count > limit ? " 等 \(names.count) 人" : "")
    }
    /// `tidy` also rewrites the fields with the normalized values; a commit after
    /// a typing pause leaves them alone so the cursor text is not changed.
    func commitLANDrafts(tidy: Bool = true) {
        setLANNickname(lanNicknameDraft); setLANRoomCode(lanRoomDraft)
        if tidy {
            if lanNicknameDraft != lanNickname { lanNicknameDraft = lanNickname }
            if lanRoomDraft != lanRoomCode { lanRoomDraft = lanRoomCode }
        }
        draftCommit?.cancel(); draftCommit = nil
    }
    private func scheduleDraftCommit() {
        draftCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitLANDrafts(tidy: false) }
        draftCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now()+0.8, execute: work)
    }
    func setLANNickname(_ raw: String) {
        let name = LANProtocol.sanitizeName(raw)
        let next = name.isEmpty ? AppModel.defaultNickname : name
        guard next != lanNickname else { return }
        lanNickname = next
        defaults.set(next, forKey: "lanNickname")
        restartLAN()
    }
    func setLANRoomCode(_ raw: String) {
        let next = LANProtocol.normalizeRoomCode(raw)
        guard next != lanRoomCode else { return }
        lanRoomCode = next
        defaults.set(next, forKey: "lanRoomCode")
        restartLAN()
    }
    /// A blue ping at the center of the main screen, for both sides to check the
    /// connection without Accessibility. Shown here with our own nickname.
    func sendTestSignal() {
        guard lanEnabled else { return }
        guard !lanRoomCode.isEmpty else { showNotice("先填写房间码"); return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        overlay.showPing(.generic, at: LANGeometry.denormalize(center, in: screen.frame), scale: scale, label: lanNickname)
        sound.play(.generic, volume: volume)
        lan.sendPing(.generic, at: center) { [weak self] count in
            self?.showNotice(count > 0 ? "测试信号已发给 \(count) 位队友" : "还没有连上队友，只在本机显示")
        }
    }
    private func restartLAN() {
        guard lanEnabled, !lanRoomCode.isEmpty else {
            lan.stop(); clearTeammateEffects()
            lanStatus = .stopped; lanPeers = LANSession.Peers()
            onStateChange?()
            return
        }
        lan.start(room: lanRoomCode, name: lanNickname)
        onStateChange?()
    }
    private func showNotice(_ text: String) {
        noticeCleanup?.cancel()
        lanNotice = text
        let cleanup = DispatchWorkItem { [weak self] in self?.lanNotice = "" }
        noticeCleanup = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now()+4, execute: cleanup)
    }
    private func sendToTeammates(_ kind: PingKind, at anchor: CGPoint) {
        if relayEnabled && relay.isActive { relay.sendPing(kind); return }
        guard lanEnabled, !lanRoomCode.isEmpty else { return }
        let frames = NSScreen.screens.map(\.frame)
        guard let frame = LANGeometry.screenIndex(containing: anchor, in: frames).map({ frames[$0] }) ?? NSScreen.main?.frame else { return }
        lan.sendPing(kind, at: LANGeometry.normalize(anchor, in: frame))
    }
    /// Same relative spot, on whichever screen this player's mouse is on. Only
    /// the visible ripple, icon and name are kept on that screen (overlays sit
    /// above the menu bar and Dock); the transparent panel may hang off it.
    private func showTeammate(_ message: LANMessage, playSound: Bool) {
        guard lanEnabled, case .ping(let kind, let position) = message.body else { return }
        let screens = NSScreen.screens
        let index = LANGeometry.screenIndex(containing: NSEvent.mouseLocation, in: screens.map(\.frame))
        guard let screen = index.map({ screens[$0] }) ?? NSScreen.main ?? screens.first else { return }
        let point = LANGeometry.denormalize(position, in: screen.frame)
        let content = OverlayController.pingContent(scale: scale, label: message.name)
        let anchor = LANGeometry.clampedAnchor(point, content: content, within: screen.frame)
        overlay.showPing(kind, at: anchor, scale: scale, label: message.name, teammate: true)
        if playSound && !lanMuteTeammates { teammateSound.play(kind, volume: volume) }
    }
    private func restartInputIfNeeded() {
        cancelEffects()
        if isEnabled && !editingShortcut { setEnabled(true) }
        onStateChange?()
    }
    func beginShortcutEditing() {
        editingShortcut = true; input.stop(); cancelEffects()
    }
    func endShortcutEditing() {
        editingShortcut = false; restartInputIfNeeded()
    }
    private func handle(_ action: GestureMachine.Action) {
        guard isEnabled else { return }
        switch action {
        case .show(let anchor): input.setWheelCenter(overlay.showWheel(at: anchor, scale: scale))
        case .hover(let kind, let angle): overlay.select(kind, angle: angle)
        case .hide: overlay.hideWheel(animated: false)
        case .dismiss: overlay.hideWheel()
        case .commit(let kind, let anchor):
            overlay.showPing(kind, at: anchor, scale: scale)
            sound.play(kind, volume: volume)
            sendToTeammates(kind, at: anchor)
        case .arm: break
        }
    }
}
