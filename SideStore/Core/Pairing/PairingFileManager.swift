//
//  PairingFileManager.swift
//  SideStore
//
//  Created by Magesh K on 17/06/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers
import MinimuxerCommon

public struct PairingFileMetadata: Sendable {
    public let exists: Bool
    public let size: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
}

final class PairingFileManager: NSObject {
    static let shared = PairingFileManager()

    static var supportedContentTypes: [UTType] {
        var types = AppConstants.Pairing.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(contentsOf: [.propertyList, .xml])
        return types
    }

    var activeProtocol: PairingProtocol {
        minimuxerPairingProtocol()
    }

    var persistedActiveProtocol: PairingProtocol? {
        get { UserDefaults.standard.activePairingProtocol }
        set { UserDefaults.standard.activePairingProtocol = newValue }
    }

    var preferredProtocol: PairingProtocol? {
        get { UserDefaults.standard.preferredPairingProtocol }
        set { UserDefaults.standard.preferredPairingProtocol = newValue }
    }

    nonisolated func pairingFileURL(for mode: PairingProtocol) -> URL {
        let fileName = mode == .rppairing ? AppConstants.Pairing.remotePairingFileName : AppConstants.Pairing.lockdownPairingFileName
        return FileManager.default.documentsDirectory.appendingPathComponent(fileName)
    }

    nonisolated func hasPairingFile(for mode: PairingProtocol) -> Bool {
        return FileManager.default.fileExists(atPath: pairingFileURL(for: mode).path)
    }

    nonisolated func hasPairingFile() -> Bool {
        guard !UserDefaults.standard.isPairingReset else { return false }
        if let target = preferredProtocol, hasPairingFile(for: target) {
            return true
        }
        if let mode = persistedActiveProtocol, hasPairingFile(for: mode) {
            return true
        }
        return false
    }

    nonisolated func metadata(for mode: PairingProtocol) -> PairingFileMetadata {
        let fileURL = pairingFileURL(for: mode)
        let path = fileURL.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return PairingFileMetadata(exists: false, size: 0, creationDate: nil, modificationDate: nil)
        }
        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let creation = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        let mod = attrs[.modificationDate] as? Date
        return PairingFileMetadata(exists: true, size: size, creationDate: creation, modificationDate: mod)
    }

    nonisolated func fetchPairingFile(for mode: PairingProtocol) -> String? {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path),
           let contents = try? String(contentsOf: fileURL), !contents.isEmpty
        {
            return contents
        }
        return nil
    }

    nonisolated func fetchPairingFile(preferred: PairingProtocol? = nil) -> String? {
        guard !UserDefaults.standard.isPairingReset else { return nil }
        let targetPreferred = preferred ?? preferredProtocol
        if let targetPreferred, let contents = fetchPairingFile(for: targetPreferred) {
            return contents
        }
        if let persisted = persistedActiveProtocol {
            return fetchPairingFile(for: persisted)
        }
        return nil
    }
    
    @discardableResult
    nonisolated func parse(content: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        try PairingFileParser.parse(content: content, preferred: preferred)
    }

    /// Protocol used for a combined (Lockdown + RemotePairing) file when the caller has no preference.
    /// RemotePairing needs iOS 17.4+, same cut-off iloader uses when generating the file.
    nonisolated static var defaultProtocolForCombinedFile: PairingProtocol {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0))
            ? .rppairing
            : .lockdown
    }

    /// Half of a combined file to use: `preferred`, else the saved preference, else the platform default.
    nonisolated func combinedFileTarget(preferred: PairingProtocol?) -> PairingProtocol {
        [preferred, preferredProtocol].compactMap { $0 }.first { $0 != .unknown } ?? Self.defaultProtocolForCombinedFile
    }

    /// Saves a pairing file. Combined files (as written by iloader) are split and both halves
    /// stored, which also replaces the other protocol's slot; the returned file is the
    /// `combinedFileTarget(preferred:)` half.
    @discardableResult
    func savePairingFile(contents: String, preferred: PairingProtocol? = nil) throws -> any PairingFile {
        if let halves = CombinedPairingFile.split(content: contents) {
            let target = combinedFileTarget(preferred: preferred)
            debugLog("[PairingFile] Combined pairing file detected, splitting into lockdown and rppairing (target: \(target.rawValue))")
            // Write the target half first so a failure leaves the other slot untouched
            let parsed = try savePairingFile(contents: halves[target]!, preferred: target)
            for (mode, half) in halves where mode != target {
                try writePairingFile(contents: half, mode: mode)
            }
            return parsed
        }

        let parsed = try parse(content: contents, preferred: preferred)
        try writePairingFile(contents: contents, mode: parsed.mode)
        UserDefaults.standard.isPairingReset = false
        return parsed
    }

    private func writePairingFile(contents: String, mode: PairingProtocol) throws {
        // Atomic write replaces the file in place, so concurrent readers never see it missing
        let destinationURL = pairingFileURL(for: mode)
        try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        debugLog("[PairingFile] Saved \(mode.rawValue) pairing file to: \(destinationURL.path)")
    }

    private let legacyImportLock = NSLock()

    /// Imports `ALTPairingFile.mobiledevicepairing` dropped into Documents by external tools
    /// (iloader, idevice_pair), then removes it. Runs on every launch since those tools can place
    /// the file at any time, not only before the first launch.
    @discardableResult
    func importLegacyPairingFileIfPresent() -> Bool {
        legacyImportLock.withLock { importLegacyPairingFileLocked() }
    }

    private func importLegacyPairingFileLocked() -> Bool {
        let fm = FileManager.default
        let legacyURL = fm.documentsDirectory.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName)
        guard fm.fileExists(atPath: legacyURL.path) else { return false }

        guard let content = try? String(contentsOf: legacyURL, encoding: .utf8), !content.isEmpty else {
            debugLog("[PairingFile] Legacy pairing file at \(legacyURL.path) is empty or unreadable, leaving it in place")
            return false
        }

        do {
            // No preference here: idevice_pair writes single-protocol files that must be stored as
            // what they contain, combined files already fall back to the saved preference
            let parsed = try savePairingFile(contents: content)
            persistedActiveProtocol = parsed.mode
            try? fm.removeItem(at: legacyURL)
            debugLog("[PairingFile] Imported legacy pairing file as \(parsed.mode.rawValue)")
            if let preferred = preferredProtocol, preferred != parsed.mode {
                if hasPairingFile(for: preferred) {
                    debugLog("[PairingFile] Preferred protocol is \(preferred.rawValue), its existing pairing file stays in use over the imported \(parsed.mode.rawValue) one")
                } else {
                    // Nothing to honor the preference with, and startMinimuxer would parse the imported file with it and fail
                    preferredProtocol = parsed.mode
                    debugLog("[PairingFile] Preferred \(preferred.rawValue) pairing file is missing, switched preference to imported \(parsed.mode.rawValue)")
                }
            }
            return true
        } catch {
            debugLog("[PairingFile] Failed to import legacy pairing file, leaving it in place: \(error)")
            return false
        }
    }

    /// Repairs state left by the old one-shot migration (nightly builds after dual pairing support):
    /// it copied iloader's combined file verbatim into both slots and recorded no protocol, so
    /// `fetchPairingFile()` found nothing. Splits combined slots on disk and, when no protocol is
    /// recorded, activates a usable slot. Needs proper testing with such upgraded installs.
    func recoverPairingStateIfNeeded() {
        legacyImportLock.withLock {
            for mode in [PairingProtocol.rppairing, .lockdown] {
                guard let contents = fetchPairingFile(for: mode),
                      let halves = CombinedPairingFile.split(content: contents) else { continue }
                for (halfMode, half) in halves {
                    try? writePairingFile(contents: half, mode: halfMode)
                }
                debugLog("[PairingFile] Split combined pairing file found in \(mode.rawValue) slot")
            }

            guard preferredProtocol == nil, persistedActiveProtocol == nil else { return }
            let candidates = Self.defaultProtocolForCombinedFile == .rppairing
                ? [PairingProtocol.rppairing, .lockdown]
                : [PairingProtocol.lockdown, .rppairing]
            for mode in candidates {
                guard let contents = fetchPairingFile(for: mode),
                      (try? parse(content: contents, preferred: mode)) != nil else { continue }
                // Files only reach the slots through an import, so a stale reset flag is safe to clear
                persistedActiveProtocol = mode
                UserDefaults.standard.isPairingReset = false
                debugLog("[PairingFile] Activated existing \(mode.rawValue) pairing file with no recorded protocol")
                return
            }
        }
    }

    /// `combinedPreference` picks which half of a combined (Lockdown + RemotePairing) file is reported;
    /// single-protocol files are always reported as what they contain.
    func inspectPairingFile(from url: URL, combinedPreference: PairingProtocol? = nil) throws -> (content: String, file: any PairingFile) {
        let isSecured = url.startAccessingSecurityScopedResource()
        defer {
            if isSecured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        // A combined file is valid for either protocol, report it as the one that would be used
        let resolvedPreferred = CombinedPairingFile.split(content: content) != nil
            ? combinedFileTarget(preferred: combinedPreference)
            : nil
        let parsed = try parse(content: content, preferred: resolvedPreferred)
        return (content, parsed)
    }

    func importPairingFile(from url: URL, preferred: PairingProtocol? = nil) throws {
        let (content, _) = try inspectPairingFile(from: url, combinedPreference: preferred)
        let parsed = try savePairingFile(contents: content, preferred: preferred)
        persistedActiveProtocol = parsed.mode
    }

    func deletePairingFile(for mode: PairingProtocol) {
        let fileURL = pairingFileURL(for: mode)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
            debugLog("[PairingFile] Deleted \(mode.rawValue) pairing file: \(fileURL.path)")
        }
        if mode == persistedActiveProtocol {
            persistedActiveProtocol = nil
        }
    }

    func resetAllPairingFiles() {
        let fm = FileManager.default
        let files = [
            AppConstants.Pairing.lockdownPairingFileName,
            AppConstants.Pairing.remotePairingFileName,
            AppConstants.Pairing.legacyPairingFileName
        ]
        for name in files {
            let path = fm.documentsDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
        UserDefaults.standard.isPairingReset = true
        persistedActiveProtocol = nil
        debugLog("[PairingFile] Reset all pairing files.")
    }
}
