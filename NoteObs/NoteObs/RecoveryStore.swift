import CryptoKit
import Foundation
import os

/// Mirrors a slot's text outside the notes folder for as long as the write into that folder is
/// owed, and deletes the mirror once the folder confirms it.
///
/// The notes folder is a synced drive: it can be paused, plugged out, or replaced with an older
/// revision mid-write. If the app dies while a change is still queued, that change exists nowhere
/// else. A mirror that still exists at launch therefore means exactly one thing: the previous
/// session owed the folder a write.
///
/// Mirrors are scoped to the folder path they were owed to, so switching to a different folder
/// cannot present another folder's unwritten text as a recovery offer.
struct RecoveryStore: Sendable {
    let baseDirectory: URL
    let directoryURL: URL
    /// Older builds scoped mirrors by the raw path string, which can name the same folder
    /// differently. Those directories are still read, so an upgrade cannot hide a pending write.
    let legacyDirectories: [URL]

    /// One queue for every scope: two views of the same folder must agree on the order a mirror
    /// was written and then discarded, which separate per-scope queues cannot promise.
    private static let ioQueue = DispatchQueue(label: "NoteObs.RecoveryStore", qos: .utility)

    init(baseDirectory: URL = RecoveryStore.defaultDirectoryURL(), scopingTo folderPath: String? = nil) {
        let primary = folderPath.map {
            RecoveryStore.scopeDirectory(base: baseDirectory, path: $0, key: NotesFolderIdentity.key(for: $0))
        } ?? baseDirectory
        let legacy: [URL]
        if let folderPath {
            legacy = NotesFolderIdentity.allKeys(for: folderPath)
                .dropFirst()
                .map { RecoveryStore.scopeDirectory(base: baseDirectory, path: folderPath, key: $0) }
                .filter { $0 != primary }
        } else {
            legacy = []
        }
        self.baseDirectory = baseDirectory
        self.directoryURL = primary
        self.legacyDirectories = legacy
        try? FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
    }

    /// `~/Library/Application Support/NoteObs/recovery` — deliberately not inside the notes folder,
    /// so a sync conflict or a rollback of the notes cannot erase the only copy of the text.
    static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NoteObs/recovery", isDirectory: true)
    }

    private static let log = Logger(subsystem: "dev.martystev.noteobs", category: "recovery")

    /// Builds before the rename to NoteObs kept their mirrors under `Application Support/TotClone`.
    /// A mirror still sitting there is text a folder is owed, so it is merged into the new tree even
    /// when that tree already exists: every mirror the new tree lacks moves over, and a mirror the new
    /// tree already has stays where it is — the new one is newer, and the old one is never deleted.
    ///
    /// Answers how many entries were moved.
    @discardableResult
    static func adoptLegacyDirectory(
        legacy: URL = legacyDirectoryURL(),
        current: URL = defaultDirectoryURL()
    ) -> Int {
        guard isDirectory(legacy) else { return 0 }
        do {
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        } catch {
            log.error("Cannot create \(current.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
        return merge(from: legacy, into: current)
    }

    private static func merge(from source: URL, into destination: URL) -> Int {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: source.path) else { return 0 }
        var moved = 0
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: to.path) {
                do {
                    try fileManager.moveItem(at: from, to: to)
                    moved += 1
                } catch {
                    log.error("Cannot move mirror \(from.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } else if isDirectory(from), isDirectory(to) {
                moved += merge(from: from, into: to)
            } else {
                log.notice("Kept legacy mirror \(from.path, privacy: .public): a newer one already exists")
            }
        }
        // Only an emptied directory goes; anything left behind stays readable on disk.
        if (try? fileManager.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
            try? fileManager.removeItem(at: source)
        }
        return moved
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func legacyDirectoryURL() -> URL {
        defaultDirectoryURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TotClone/recovery", isDirectory: true)
    }

    /// Narrows this store to the mirrors owed to one notes folder.
    func scoped(to folderPath: String) -> RecoveryStore {
        RecoveryStore(baseDirectory: baseDirectory, scopingTo: folderPath)
    }

    private static func scopeDirectory(base: URL, path: String, key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let fingerprint = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = URL(fileURLWithPath: path).lastPathComponent
        return base.appendingPathComponent("\(name.isEmpty ? "folder" : name)-\(fingerprint)", isDirectory: true)
    }

    func fileURL(for index: Int) -> URL {
        directoryURL.appendingPathComponent("slot\(index + 1).md")
    }

    private var directories: [URL] {
        [directoryURL] + legacyDirectories
    }

    func mirror(text: String, index: Int) {
        let url = fileURL(for: index)
        Self.ioQueue.async {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func discard(index: Int) {
        let urls = directories.map { $0.appendingPathComponent("slot\(index + 1).md") }
        Self.ioQueue.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func contents(ofSlotAt index: Int) -> String? {
        let urls = directories.map { $0.appendingPathComponent("slot\(index + 1).md") }
        return Self.ioQueue.sync {
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return nil
        }
    }

    /// Waits for queued mirror writes to land; used when the process is about to disappear.
    func settle() {
        Self.ioQueue.sync {}
    }
}
