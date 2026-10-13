import Foundation
import CryptoKit

// Independent public-key-only verification of release files. Never reads a
// private key, starts an updater, installs anything, or changes preferences.
final class Enclosures: NSObject, XMLParserDelegate {
    var items = [[String: String]]()
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "enclosure" { items.append(attributes) }
    }
}

do {
    guard CommandLine.arguments.count == 4 else { throw NSError(domain: "Usage: verify-update.swift Info.plist appcast.xml update.zip", code: 1) }
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])), format: nil) as! [String: Any]
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: plist["SUPublicEDKey"] as! String)!)
    let feed = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let xml = String(decoding: feed, as: UTF8.self)
    guard let block = xml.range(of: "<!-- sparkle-signatures:", options: .backwards) else { fatalError("Missing signed feed") }
    let lines = xml[block.upperBound...].split(separator: "\n")
    let signature = Data(base64Encoded: String(lines.first { $0.hasPrefix("edSignature: ") }!.dropFirst(13)))!
    let length = Int(lines.first { $0.hasPrefix("length: ") }!.dropFirst(8))!
    guard length > 0 && length < feed.count else { fatalError("Invalid feed length") }
    let signedFeed = Data(feed.prefix(length))
    precondition(key.isValidSignature(signature, for: signedFeed), "Invalid appcast signature")
    let parser = XMLParser(data: feed), enclosures = Enclosures()
    parser.delegate = enclosures
    precondition(parser.parse(), "Invalid XML")
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let filename = URL(fileURLWithPath: CommandLine.arguments[3]).lastPathComponent
    let enclosure = enclosures.items.first { URL(string: $0["url"] ?? "")?.lastPathComponent == filename }!
    let archiveSignature = Data(base64Encoded: enclosure["sparkle:edSignature"]!)!
    precondition(Int(enclosure["length"]!) == archive.count, "Archive length mismatch")
    precondition(key.isValidSignature(archiveSignature, for: archive), "Invalid ZIP signature")
    for (name, data, signature) in [("feed", signedFeed, signature), ("ZIP", archive, archiveSignature)] {
        var changed = data; changed[changed.count/2] ^= 1
        precondition(!key.isValidSignature(signature, for: changed), "Tampered \(name) accepted")
        let wrongKey = Curve25519.Signing.PrivateKey().publicKey
        precondition(!wrongKey.isValidSignature(signature, for: data), "Wrong key accepted for \(name)")
    }
    print("PASS Ed25519: signed feed and ZIP; tampered feed/ZIP and wrong public keys rejected")
} catch { print("Update verification failed: \(error)"); exit(1) }
