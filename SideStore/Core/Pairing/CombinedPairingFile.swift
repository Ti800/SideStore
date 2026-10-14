//
//  CombinedPairingFile.swift
//  SideStore
//
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import MinimuxerCommon

/// iloader (iOS 17.4+) writes a single plist holding both the Lockdown pair record and the
/// RemotePairing credentials. PairingFileParser rejects such files as ambiguous, so they are
/// split into one file per protocol before being stored.
enum CombinedPairingFile {
    // Keys written by idevice's RpPairingFile; everything else belongs to the Lockdown pair record
    static let remotePairingKeys: Set<String> = ["public_key", "private_key", "identifier", "alt_irk"]

    /// Returns one unambiguous pairing file per protocol, or nil when `content` is not a combined file.
    static func split(content: String) -> [PairingProtocol: String]? {
        guard (try? PairingFileParser.parse(content: content, preferred: .rppairing)) != nil,
              (try? PairingFileParser.parse(content: content, preferred: .lockdown)) != nil,
              let data = content.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        let remote = plist.filter { remotePairingKeys.contains($0.key) }
        let lockdown = plist.filter { !remotePairingKeys.contains($0.key) }

        guard let remoteContent = xmlString(from: remote),
              let lockdownContent = xmlString(from: lockdown),
              (try? PairingFileParser.parse(content: remoteContent))?.mode == .rppairing,
              (try? PairingFileParser.parse(content: lockdownContent))?.mode == .lockdown
        else {
            return nil
        }

        return [.rppairing: remoteContent, .lockdown: lockdownContent]
    }

    private static func xmlString(from plist: [String: Any]) -> String? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
