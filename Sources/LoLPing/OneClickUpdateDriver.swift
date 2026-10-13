import Foundation
import Sparkle

/// Retains Sparkle's standard progress/error UI. Only an explicit update choice
/// can start installation, then the ready-to-relaunch step needs no second click.
final class OneClickUpdateDriver: NSObject, SPUUserDriver {
    let standard: SPUStandardUserDriver
    var installRequested = false
    private var pendingInstall: ((SPUUserUpdateChoice) -> Void)?

    init(delegate: SPUStandardUserDriverDelegate) {
        standard = SPUStandardUserDriver(hostBundle: .main, delegate: delegate)
        super.init()
    }

    func installPendingUpdate() -> Bool {
        guard let reply = pendingInstall else { return false }
        pendingInstall = nil; installRequested = true
        reply(.install)
        return true
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if !state.userInitiated && !appcastItem.isInformationOnlyUpdate {
            // Keep the scheduled update ready for the in-app "Update now"
            // button instead of creating a second confirmation window.
            pendingInstall = reply
        } else if installRequested && state.userInitiated && !appcastItem.isInformationOnlyUpdate {
            reply(.install)
        } else {
            standard.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
                self?.installRequested = choice == .install
                reply(choice)
            }
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { standard.showUpdateReleaseNotes(with: downloadData) }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { standard.showDownloadInitiated(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installRequested { reply(.install) }
        else { standard.showReady(toInstallAndRelaunch: reply) }
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func dismissUpdateInstallation() { pendingInstall = nil; installRequested = false; standard.dismissUpdateInstallation() }
    func showUpdateInFocus() {
        if installRequested && installPendingUpdate() { return }
        standard.showUpdateInFocus()
    }
}
