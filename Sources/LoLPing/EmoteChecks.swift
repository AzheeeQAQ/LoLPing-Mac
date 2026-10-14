import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PingCore

/// Exercises the production import, input router and transports using isolated files and unposted events.
enum EmoteChecks {
    static func run(endpoint: String, screenshots: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let fm = FileManager.default, scratch = fm.temporaryDirectory.appendingPathComponent("LoLPing-emote-check-"+UUID().uuidString)
        let suite = "LoLPing-EmoteChecks-"+UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        var failures: [String] = []
        func check(_ value: Bool, _ title: String) { if !value { failures.append(title); print("FAIL \(title)") } }
        func spin(_ time: Double) { RunLoop.main.run(until: Date().addingTimeInterval(time)) }
        func wait(_ condition: () -> Bool, seconds: Double = 10) { let until = Date().addingTimeInterval(seconds); while !condition() && Date() < until { spin(0.03) } }
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: scratch) }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            try fm.createDirectory(at: screenshots, withIntermediateDirectories: true)
            let context = CGContext(data: nil, width: 500, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.systemMint.cgColor); context.fillEllipse(in: CGRect(x: 80, y: 0, width: 300, height: 300))
            context.setFillColor(NSColor.black.cgColor)
            for x in [160, 270] { context.fillEllipse(in: CGRect(x: x, y: 170, width: 35, height: 35)) }
            context.fill(CGRect(x: 175, y: 80, width: 110, height: 18))
            let art = context.makeImage()!
            let sourceFile = scratch.appendingPathComponent("我的表情.png")
            let destination = CGImageDestinationCreateWithURL(sourceFile as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, art, nil); check(CGImageDestinationFinalize(destination), "PNG fixture")
            let libraryDir = scratch.appendingPathComponent("library")
            let library = EmoteLibrary(directory: libraryDir)
            try library.importImage(sourceFile)
            check(library.items.count == 1 && library.wheel == WheelLayout.defaults, "import preserves the current wheel until a slot is chosen")
            let id = library.items[0].id, payload = library.payload(id)!
            check(payload.isValid && EmoteLibrary.decode(payload) != nil, "normalized PNG decodes, fits 160 px and 32 KB")
            do { try library.importImage(sourceFile); check(false, "duplicate rejected") } catch {}
            library.assign(id, to: 7); library.rename(id, to: "新名称\n")
            let restored = EmoteLibrary(directory: libraryDir)
            check(restored.items[0].name == "新名称" && restored.slots[7] == id, "library, names and wheel persist")
            let gifFile = scratch.appendingPathComponent("动图.gif")
            let gif = CGImageDestinationCreateWithURL(gifFile as CFURL, UTType.gif.identifier as CFString, 2, nil)!
            CGImageDestinationAddImage(gif, art, nil)
            context.setFillColor(NSColor.systemOrange.cgColor); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            CGImageDestinationAddImage(gif, context.makeImage()!, nil); check(CGImageDestinationFinalize(gif), "GIF fixture")
            let gifLibrary = EmoteLibrary(directory: scratch.appendingPathComponent("gif"))
            try gifLibrary.importImage(gifFile)
            let gifPayload = gifLibrary.payload(gifLibrary.items[0].id)!
            check(CGImageSourceGetCount(CGImageSourceCreateWithData(gifPayload.png as CFData, nil)!) == 1, "GIF imported as still first frame")
            let jpegFile = scratch.appendingPathComponent("照片.jpg")
            let jpeg = CGImageDestinationCreateWithURL(jpegFile as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(jpeg, context.makeImage()!, nil); check(CGImageDestinationFinalize(jpeg), "JPEG fixture")
            try library.importImage(jpegFile); check(library.items.count == 2, "JPEG import")
            let webpFile = scratch.appendingPathComponent("透明图片.webp")
            try Data(base64Encoded: "UklGRhwAAABXRUJQVlA4TBAAAAAvD8ADAAdQ2qhg/wMR0f8A")!.write(to: webpFile)
            try library.importImage(webpFile); check(library.items.count == 3, "WebP import")
            let wrong = EmotePayload(id: String(repeating: "0", count: 64), name: "x", png: payload.png)
            check(EmoteLibrary.decode(wrong) == nil, "forged hash never decodes")
            let garbage = scratch.appendingPathComponent("broken.png"); try Data("not an image".utf8).write(to: garbage)
            do { try library.importImage(garbage); check(false, "invalid image rejected") } catch {}
            let over = scratch.appendingPathComponent("large.png"); try Data(repeating: 1, count: 8_388_609).write(to: over)
            do { try library.importImage(over); check(false, "oversized image rejected before decoding") } catch {}
            var assembler = LANEmoteAssembler(), assembled: EmotePayload?, deliveries = 0
            let packets = LANEmoteChunk.packets(payload, room: "room", sender: UUID().uuidString, name: "朋友", at: CGPoint(x: 0.3, y: 0.7))
            check(!packets.isEmpty && packets.allSatisfy { $0.count <= 1024 }, "LAN datagrams fit safe size")
            for bytes in packets.reversed()+packets {
                let chunk = try JSONDecoder().decode(LANEmoteChunk.self, from: bytes)
                if let (result, point) = assembler.accept(chunk, at: 1) { assembled = result; deliveries += 1; check(point == CGPoint(x: 0.3, y: 0.7), "LAN relative position") }
            }
            check(assembled == payload && deliveries == 1, "out-of-order LAN assembly dedupes repeat passes")
            print("PASS import: PNG/JPEG/GIF/WebP, transparent resize, hash, limits, duplicate, persistence and LAN assembly")
            check(BundledEmotes.validationFailures.isEmpty && library.bundled.count == 44, "all 44 bundled icons validate offline")
            for item in library.bundled {
                check(library.payload(item.id).flatMap(EmoteLibrary.decode) != nil, "bundled PNG hash, dimensions and decode: \(item.name)")
            }
            let builtin = library.bundled.first!.id
            library.setSlot(.emote(builtin), at: 0); library.setSlot(.ping(.assist), at: 1)
            library.setSlot(.empty, at: 2); library.setSlot(.emote(id), at: 8)
            let mixed = EmoteLibrary(directory: libraryDir)
            check(mixed.wheel == library.wheel, "mixed image/ping/empty/center wheel survives restart")
            let beforeInvalid = mixed.wheel
            mixed.setSlot(.emote(String(repeating: "0", count: 64)), at: 0); mixed.setSlot(.ping(.missing), at: 9)
            check(mixed.wheel == beforeInvalid, "unknown images and invalid positions do not replace a slot")
            let legacyDir = scratch.appendingPathComponent("legacy")
            try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
            try payload.png.write(to: legacyDir.appendingPathComponent(id+".png"))
            var legacySlots = Array(repeating: "", count: 8); legacySlots[4] = id
            try JSONEncoder().encode(EmoteLibrary.Manifest(items: [CustomEmote(id: id, name: payload.name)], slots: legacySlots, wheel: nil))
                .write(to: legacyDir.appendingPathComponent("library.json"))
            let migrated = EmoteLibrary(directory: legacyDir)
            check(migrated.wheel[4] == .emote(id) && migrated.wheel[0] == .ping(.retreat) && migrated.wheel[8] == .ping(.generic), "legacy images migrate to mixed wheel without losing other pings")
            migrated.setSlot(.ping(.push), at: 0)
            check(EmoteLibrary(directory: legacyDir).wheel == migrated.wheel, "migration persists new layout on first edit")
            mixed.resetWheel(); check(mixed.wheel == WheelLayout.defaults && mixed.items.count == 3 && mixed.bundled.count == 44, "reset keeps both image libraries")
            mixed.remove(builtin); check(mixed.bundled.count == 44 && mixed.payload(builtin) != nil, "bundled icons cannot be deleted as custom files")
            print("PASS unified wheel: 44 offline images, mixed slot/center persistence, validation, legacy migration and reset")
            defaults.set(false, forKey: "emoteEnabled") // Removed legacy switch must not block the shared wheel.
            let model = AppModel(defaults: defaults, emoteDirectory: libraryDir)
            defer { model.leaveRelayRoom(); model.shutdown() }
            model.emotes.setSlot(.emote(builtin), at: 0); model.emotes.setSlot(.ping(.assist), at: 1)
            model.emotes.setSlot(.empty, at: 2); model.emotes.setSlot(.emote(id), at: 8)
            let hosting = NSHostingView(rootView: WheelControlView(model: model, library: model.emotes).padding(20).frame(width: 600).tint(Color(red: 0.83, green: 0.70, blue: 0.44)).preferredColorScheme(.dark))
            hosting.appearance = NSAppearance(named: .darkAqua)
            hosting.frame = CGRect(x: 0, y: 0, width: 600, height: hosting.fittingSize.height)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: screenshots.appendingPathComponent("emote-settings.png"))
            } else { check(false, "settings snapshot") }
            let wheel = WheelView(frame: CGRect(x: 0, y: 0, width: 450, height: 450))
            wheel.configure(model.emotes)
            wheel.setSelection(.retreat, angle: 0, animated: false)
            try VisualChecks.save(VisualChecks.bitmap(size: wheel.bounds.size) { VisualChecks.draw(wheel, at: .zero) }, to: screenshots.appendingPathComponent("emote-wheel.png"))
            let effect = EmoteEffectView(frame: CGRect(x: 0, y: 0, width: 220, height: 220), image: library.image(id)!, label: "联机朋友")
            effect.seek(0.7)
            try VisualChecks.save(VisualChecks.bitmap(size: effect.bounds.size) { VisualChecks.draw(effect, at: .zero) }, to: screenshots.appendingPathComponent("emote-effect.png"))
            library.assign(id, to: 7); library.assign(id, to: 8)
            library.remove(id); let deleted = EmoteLibrary(directory: libraryDir)
            check(deleted.wheel[7] == .empty && deleted.wheel[8] == .empty, "delete clears every outer and center reference")
            // Real clients and server: images never enter the recipient's personal library.
            let a = RelayClient(defaults: nil), b = RelayClient(defaults: nil)
            defer { a.disconnect(); b.disconnect(); spin(0.15) }
            a.serverAddress = endpoint; b.serverAddress = endpoint; a.displayName = "表情甲"; b.displayName = "表情乙"
            a.createRoom(); wait { a.state == .connected }; check(a.state == .connected, "relay create: \(a.status)")
            if a.state == .connected {
                b.roomInput = a.room; b.joinRoom(); wait { b.state == .connected && a.peers.count == 2 }
                var gotA = 0, gotB = 0
                a.onEmote = { value, sender in check(value == payload && sender == "表情乙" && EmoteLibrary.decode(value) != nil, "A receives correct remote image"); gotA += 1 }
                b.onEmote = { value, sender in check(value == payload && sender == "表情甲" && EmoteLibrary.decode(value) != nil, "B receives correct remote image"); gotB += 1 }
                a.sendEmote(payload); b.sendEmote(payload); wait { gotA == 1 && gotB == 1 }
                check(gotA == 1 && gotB == 1, "two-way production relay image delivery")
                spin(1.1); b.receiveEnabled = false; a.sendEmote(payload); spin(0.3); check(gotB == 1, "receive off suppresses image")
                spin(1.1); b.receiveEnabled = true; b.reconnectAfterWake(); wait { b.state == .connected && a.peers.count == 2 }
                a.sendEmote(payload); wait { gotB == 2 }; check(gotB == 2, "image delivery resumes after reconnect")
                print("PASS production relay images: both directions, receive toggle and reconnect")
            }
            a.disconnect(); b.disconnect(); spin(0.2)
            let peer = RelayClient(defaults: nil)
            defer { peer.disconnect() }
            model.relay.serverAddress = endpoint; model.relay.displayName = "统一轮盘甲"
            peer.serverAddress = endpoint; peer.displayName = "统一轮盘乙"
            model.relayEnabled = true; model.createRelayRoom(); wait { model.relay.state == .connected }
            check(model.relay.state == .connected, "unified wheel room connects")
            if model.relay.state == .connected {
                peer.roomInput = model.relay.room; peer.joinRoom(); wait { peer.state == .connected && model.relay.peers.count == 2 }
                model.emotes.setSlot(.emote(builtin), at: 0); model.emotes.setSlot(.ping(.assist), at: 1)
                model.emotes.setSlot(.empty, at: 2); model.emotes.setSlot(.emote(builtin), at: 8)
                var receivedImages: [String] = [], receivedPings: [PingKind] = []
                peer.onEmote = { value, _ in check(EmoteLibrary.decode(value) != nil, "bundled image receives as actual PNG"); receivedImages.append(value.id) }
                peer.onPing = { value, _ in receivedPings.append(value) }
                let input = GlobalInput(mouseButtonsDown: { false })
                input.configure(chord: TriggerChord(modifiers: [.control], keyCode: 0)!)
                input.onAction = { if case .commit(let selection, let anchor) = $0 { model.sendWheelSelection(selection, at: anchor) } }
                func gesture(_ vector: CGPoint) {
                    let top = NSScreen.screens.first?.frame.maxY ?? 0
                    let anchor = CGPoint(x: 300, y: 300)
                    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
                    down.flags = .maskControl; down.location = CGPoint(x: anchor.x, y: top-anchor.y)
                    check(input.process(.keyDown, down), "shared trigger down is swallowed")
                    spin(0.23)
                    let moved = CGEvent(source: nil)!; moved.flags = .maskControl
                    moved.location = CGPoint(x: anchor.x+vector.x, y: top-anchor.y-vector.y)
                    _ = input.process(.mouseMoved, moved)
                    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
                    up.flags = .maskControl; up.location = moved.location
                    check(input.process(.keyUp, up), "shared trigger release is swallowed")
                    let released = CGEvent(source: nil)!; released.flags = []
                    _ = input.process(.flagsChanged, released)
                }
                gesture(CGPoint(x: 0, y: 100)); wait { receivedImages.count == 1 }
                check(receivedImages == [builtin] && receivedPings.isEmpty, "same chord up slot sends selected builtin image")
                spin(1.1); gesture(CGPoint(x: 100, y: 100)); wait { receivedPings.count == 1 }
                check(receivedPings == [.assist], "same chord diagonal sends replaced ping, not original slot kind")
                spin(1.1); gesture(CGPoint(x: 100, y: 0)); spin(0.3)
                check(receivedImages.count == 1 && receivedPings.count == 1, "empty slot sends nothing")
                gesture(.zero); wait { receivedImages.count == 2 }
                check(receivedImages == [builtin,builtin], "same chord center can send replaced image")
                input.stop()
                print("PASS shared trigger production gesture commits: selected image, remapped ping, empty slot and custom center over public relay")
            }
            let lanA = LANSession(), lanB = LANSession(), room = String(UUID().uuidString.prefix(8))
            defer { lanA.stop(); lanB.stop() }
            var ready = false, lanGot = 0
            lanA.onPeers = { if $0.connected > 0 { ready = true } }
            lanB.onEmote = { value, sender, position in
                check(value == payload && EmoteLibrary.decode(value) != nil && sender == "LAN甲" && position == CGPoint(x: 0.2, y: 0.8), "LAN image with sender and position"); lanGot += 1
            }
            lanA.start(room: room, name: "LAN甲"); lanB.start(room: room, name: "LAN乙")
            wait({ ready }, seconds: 12); check(ready, "Bonjour LAN peers connect")
            if ready { lanA.sendEmote(payload, at: CGPoint(x: 0.2, y: 0.8)); wait { lanGot == 1 }; spin(0.8); check(lanGot == 1, "production LAN image delivered once"); print("PASS production Bonjour LAN custom image") }
        } catch { failures.append(error.localizedDescription); print("FAIL \(error)") }
        print(failures.isEmpty ? "All custom emote checks passed." : "\(failures.count) custom emote failures")
        return failures.isEmpty ? 0 : 1
    }
}
