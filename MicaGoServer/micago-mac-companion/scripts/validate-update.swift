#!/usr/bin/env swift
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

final class AppcastReader: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    var fields: [String: String] = [:]
    private var field: String?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "enclosure" { enclosures.append(attributes) }
        if ["sparkle:version", "sparkle:shortVersionString"].contains(name) { field = name; fields[name] = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        if let field { fields[field, default: ""] += text }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if field == name { field = nil }
    }
}

func validate(appcast: URL, archive: URL, info: URL, version: String) throws {
    let xml = try Data(contentsOf: appcast)
    let reader = AppcastReader()
    let parser = XMLParser(data: xml)
    parser.delegate = reader
    guard parser.parse(), reader.enclosures.count == 1 else {
        throw NSError(domain: "UpdateValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected one valid update enclosure"])
    }
    let enclosure = reader.enclosures[0]
    let expected = "https://github.com/cinmou/MicaGo/releases/download/v\(version)/\(archive.lastPathComponent)"
    guard enclosure["url"] == expected else {
        throw NSError(domain: "UpdateValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Download URL does not match this release archive"])
    }
    let payload = try Data(contentsOf: archive, options: .mappedIfSafe)
    guard enclosure["length"] == String(payload.count) else {
        throw NSError(domain: "UpdateValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Archive length mismatch"])
    }
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
    let build = (reader.fields["sparkle:version"] ?? enclosure["sparkle:version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    let shortVersion = (reader.fields["sparkle:shortVersionString"] ?? enclosure["sparkle:shortVersionString"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let build, let bundledBuild = plist?["CFBundleVersion"] as? String,
          build == bundledBuild, shortVersion == version,
          plist?["CFBundleShortVersionString"] as? String == version else {
        throw NSError(domain: "UpdateValidation", code: 6, userInfo: [NSLocalizedDescriptionKey: "Appcast and application versions do not match"])
    }
    guard let publicKey = plist?["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: publicKey),
          let rawSignature = enclosure["sparkle:edSignature"],
          let signature = Data(base64Encoded: rawSignature) else {
        throw NSError(domain: "UpdateValidation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing update verification key or signature"])
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: payload) else {
        throw NSError(domain: "UpdateValidation", code: 5, userInfo: [NSLocalizedDescriptionKey: "Signature does not match the public key embedded in the app"])
    }
}

guard CommandLine.arguments.count == 5 else {
    fputs("usage: validate-update.swift appcast.xml archive Info.plist version\n", stderr)
    exit(2)
}
do {
    let args = CommandLine.arguments
    try validate(appcast: URL(fileURLWithPath: args[1]), archive: URL(fileURLWithPath: args[2]), info: URL(fileURLWithPath: args[3]), version: args[4])
    print("Update archive URL, size and embedded-key signature verified")
} catch {
    fputs("Update validation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
