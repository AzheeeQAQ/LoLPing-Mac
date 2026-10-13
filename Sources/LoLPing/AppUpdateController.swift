import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle owns checking, signature verification, replacement and relaunch.
/// Scheduled checks surface a quiet in-app reminder so games keep focus.
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var status = "启动时和每隔 1 小时检查更新。"
    @Published private(set) var lastCheck: Date?
    private(set) var updater: SPUUpdater!
    private var driver: OneClickUpdateDriver!
    var onStateChange: (() -> Void)?
    private var observations = Set<AnyCancellable>()
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    var buttonTitle: String { availableVersion.map { "立即更新至 \($0)" } ?? "检查更新…" }

    override init() {
        super.init()
        driver = OneClickUpdateDriver(delegate: self)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            self?.canCheck = value; self?.onStateChange?()
        }.store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in
            self?.automaticallyChecks = value
        }.store(in: &observations)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] value in
            self?.lastCheck = value
        }.store(in: &observations)
    }

    func start() {
        do {
            try updater.start()
            // Sparkle schedules later checks itself and preserves the user's setting.
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            status = "更新检查暂不可用：\(error.localizedDescription)"
        }
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        NSApp.activate(ignoringOtherApps: true)
        driver.installRequested = availableVersion != nil
        if driver.installPendingUpdate() { return }
        updater.checkForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        status = "有新版本，点击更新后下载并安装重启。"
        onStateChange?()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil; status = "当前已是最新版本。"; onStateChange?()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        guard error.domain != SUSparkleErrorDomain || error.code != 1001 else { return }
        status = "更新未完成，可以稍后重试。"
        onStateChange?()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString; onStateChange?()
    }
}

struct AppUpdateView: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("软件更新", systemImage: "arrow.down.circle").font(.system(size: 14, weight: .semibold))
                Text("v\(updates.version)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(updates.buttonTitle) { updates.checkForUpdates() }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(!updates.canCheck)
                    .accessibilityLabel(updates.buttonTitle)
            }
            Toggle("自动检查更新", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
            Text(updates.status).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let date = updates.lastCheck {
                Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(16)
            .background(Color(red: 0.065, green: 0.090, blue: 0.120), in: RoundedRectangle(cornerRadius: 12))
    }
}
