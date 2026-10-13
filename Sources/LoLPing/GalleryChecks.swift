import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PingCore

/// Synthetic, explicitly public fixture only; never reads personal images/preferences.
enum GalleryChecks {
    static func run(endpoint: String, screenshots: URL) -> Int32 {
        _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .darkAqua)
        let fm = FileManager.default, scratch = fm.temporaryDirectory.appendingPathComponent("LoLPing-gallery-"+UUID().uuidString)
        let suiteA = "LoLPing-GalleryA-"+UUID().uuidString, suiteB = "LoLPing-GalleryB-"+UUID().uuidString
        let prefsA = UserDefaults(suiteName: suiteA)!, prefsB = UserDefaults(suiteName: suiteB)!
        let a = GalleryClient(defaults: prefsA), b = GalleryClient(defaults: prefsB)
        var failures: [String] = [], ownedID: String?
        func check(_ value: Bool, _ label: String) { if !value { failures.append(label); print("FAIL \(label)") } }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ condition: () -> Bool) { let until = Date().addingTimeInterval(20); while !condition() && Date() < until { spin(0.03) } }
        defer {
            if let id = ownedID { a.configure(endpoint); a.remove(id); wait { !a.mutating } }
            a.disconnect(); b.disconnect(); prefsA.removePersistentDomain(forName: suiteA); prefsB.removePersistentDomain(forName: suiteB)
            try? fm.removeItem(at: scratch)
        }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: screenshots, withIntermediateDirectories: true)
            let context = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.systemTeal.cgColor); context.fillEllipse(in: CGRect(x: 5, y: 5, width: 110, height: 110))
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: 35, y: 70, width: 10, height: 12)); context.fillEllipse(in: CGRect(x: 75, y: 70, width: 10, height: 12))
            context.fill(CGRect(x: 35, y: 35, width: 50, height: 7))
            // A random corner mark makes each public test fixture distinct.
            context.setFillColor(NSColor(calibratedRed: Double.random(in: 0...1), green: Double.random(in: 0...1), blue: Double.random(in: 0...1), alpha: 1).cgColor)
            context.fill(CGRect(x: 55, y: 90, width: 8, height: 8))
            let file = scratch.appendingPathComponent("公共分享测试.png")
            let target = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(target, context.makeImage()!, nil); check(CGImageDestinationFinalize(target), "fixture PNG")
            let original = EmoteLibrary(directory: scratch.appendingPathComponent("original")); try original.importImage(file)
            let id = original.items[0].id, payload = original.payload(id)!
            a.configure(endpoint); a.refresh(); wait { !a.refreshing }
            let before = Set(a.items.map(\.id))
            a.upload(payload, uploader: "公共库验证"); wait { !a.mutating }
            check(a.items.contains { $0.id == id } && a.canDelete(id), "upload is public and records owner: \(a.status)")
            if a.canDelete(id) { ownedID = id }
            let restarted = GalleryClient(defaults: prefsA); restarted.configure(endpoint)
            check(restarted.canDelete(id), "owner credential survives client restart")
            b.configure(endpoint); b.refresh(); wait { !b.refreshing }
            check(b.items.contains { $0.id == id } && !b.canDelete(id), "independent client browses without room, cannot delete")
            var downloaded: EmotePayload?, downloadDone = false
            b.load(id) { downloaded = $0; downloadDone = true }; wait { downloadDone }
            check(downloaded == payload, "exact public PNG/hash/name downloaded")
            let saved = EmoteLibrary(directory: scratch.appendingPathComponent("downloaded"))
            if let downloaded {
                check(saved.importShared(downloaded, into: 8), "download assigns center slot")
                check(saved.importShared(downloaded, into: 1) && saved.items.count == 1, "known image reused without consuming quota")
                let restored = EmoteLibrary(directory: scratch.appendingPathComponent("downloaded"))
                check(restored.payload(id) == payload && restored.wheel[8] == .emote(id), "offline image and wheel survive restart")
                let beforeInvalid = restored.wheel
                let forged = EmotePayload(id: String(repeating: "0", count: 64), name: payload.name, png: payload.png)
                check(!restored.importShared(forged, into: 0) && restored.wheel == beforeInvalid, "forged shared image cannot replace a slot")
            }
            b.upload(payload, uploader: "另一位朋友"); wait { !b.mutating }
            check(!b.canDelete(id) && b.items.first(where: { $0.id == id })?.uploader == "公共库验证", "duplicate cannot reclaim original upload")
            restarted.disconnect()
            let model = AppModel(defaults: prefsA, emoteDirectory: scratch.appendingPathComponent("original"))
            defer { model.shutdown() }
            model.relayEnabled = true; model.relay.serverAddress = endpoint
            let hosting = NSHostingView(rootView: GalleryView(model: model, library: model.emotes, gallery: a, relay: model.relay, slot: 8)
                .tint(Color(red: 0.83, green: 0.70, blue: 0.44)))
            hosting.appearance = NSAppearance(named: .darkAqua); hosting.frame = CGRect(x: 0, y: 0, width: 658, height: 658); hosting.layoutSubtreeIfNeeded()
            spin(0.1); wait { !a.refreshing }; hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: screenshots.appendingPathComponent("public-gallery.png"))
            }
            a.remove(id); wait { !a.mutating }
            check(!a.items.contains { $0.id == id } && !a.canDelete(id), "owner removes public copy")
            b.refresh(); wait { !b.refreshing }
            check(!b.items.contains { $0.id == id } && Set(b.items.map(\.id)) == before, "public fixture cleaned; existing gallery unaffected")
            check(saved.payload(id) == payload && saved.wheel[8] == .emote(id), "removing public copy keeps downloaded image and wheel")
            ownedID = nil
            model.gallery.configure(endpoint); model.relayEnabled = false
            check(model.gallery.endpoint == nil, "server switch off disconnects gallery")
            print("PASS public gallery: independent clients, upload/download, owner persistence, deduplication, offline wheel, deletion and server switch")
        } catch { failures.append(error.localizedDescription) }
        failures.forEach { print("FAIL \($0)") }
        if failures.isEmpty { print("All public gallery checks passed."); return 0 }
        return 1
    }
}
