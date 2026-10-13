import AppKit
import AVFoundation
import PingCore

if let index = CommandLine.arguments.firstIndex(of: "--gallery-check"), CommandLine.arguments.count > index+2 {
    exit(GalleryChecks.run(endpoint: CommandLine.arguments[index+1], screenshots: URL(fileURLWithPath: CommandLine.arguments[index+2])))
}

if let index = CommandLine.arguments.firstIndex(of: "--emote-check"), CommandLine.arguments.count > index+2 {
    exit(EmoteChecks.run(endpoint: CommandLine.arguments[index+1], screenshots: URL(fileURLWithPath: CommandLine.arguments[index+2])))
}

if let index = CommandLine.arguments.firstIndex(of: "--feature-check"), CommandLine.arguments.count > index+1 {
    exit(FeatureChecks.run(endpoint: CommandLine.arguments[index+1]))
}

if let index = CommandLine.arguments.firstIndex(of: "--visual-check"), CommandLine.arguments.count > index+1 {
    do { try VisualChecks.run(to: URL(fileURLWithPath: CommandLine.arguments[index+1])); exit(0) }
    catch { print("Visual check failed: \(error)"); exit(1) }
}

// This diagnostics mode never creates an event tap or synthesizes keyboard/mouse events.
if CommandLine.arguments.contains("--check-assets") {
    var failures = Assets.missingFiles
    if let problem = RelayServerTrust.validationError { failures.append(problem) }
    for kind in PingKind.allCases {
        do {
            let player = try AVAudioPlayer(contentsOf: Assets.sound(kind))
            if player.duration <= 0 { failures.append("Invalid duration: \(kind.soundName)") }
            print("\(kind.title): image=\(Assets.icon(kind)?.size ?? .zero), sound=\(String(format: "%.2f", player.duration))s")
        } catch { failures.append("\(kind.soundName): \(error.localizedDescription)") }
    }
    if failures.isEmpty { print("All 9 ping icons, 9 audio files and 44 bundled emote images decode successfully."); exit(0) }
    failures.forEach { print($0) }; exit(1)
}

// Headless LAN diagnostics: no event tap, menu bar item or window.
if let index = CommandLine.arguments.firstIndex(of: "--relay-ping-check"), CommandLine.arguments.count > index+1,
   let endpoint = RelayProtocol.endpoint(CommandLine.arguments[index+1]) {
    exit(RelayTrustChecks.ping(endpoint: endpoint))
}

if let index = CommandLine.arguments.firstIndex(of: "--relay-trust-check"), CommandLine.arguments.count > index+2 {
    exit(RelayTrustChecks.run(chainPath: CommandLine.arguments[index+1], foreignPath: CommandLine.arguments[index+2]))
}

if let index = CommandLine.arguments.firstIndex(of: "--relay-check"), CommandLine.arguments.count > index+1 {
    exit(RelayChecks.run(endpoint: CommandLine.arguments[index+1]))
}

if CommandLine.arguments.contains("--lan-listen") || CommandLine.arguments.contains("--lan-send") {
    LANCommandLine.run(CommandLine.arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
