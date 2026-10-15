import Foundation

/// Coordinates thread-safe atomic file writing operations via Swift Concurrency.
public actor FileSaveActor {
    public init() {}

    public func write(data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw NotesFileStoreError.writeFailed
        }
    }
}

/// What one slot file held when the folder was read.
public enum SlotRead: Sendable, Equatable {
    case missing
    case text(String)
    /// The file exists but its content could not be read: not valid UTF-8, or a provider that has not
    /// delivered it yet.
    case unreadable

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

public struct NotesFileStore: Sendable {
    public let folderURL: URL
    private let saveActor: FileSaveActor
    private let securityScope: SecurityScope

    /// Opens a folder for use. Pass a bookmark-resolved URL together with `securingAccess` so the
    /// grant the bookmark carries stays alive for as long as any copy of this store is around.
    public init(url: URL, securingAccess: Bool = false, saveActor: FileSaveActor = FileSaveActor()) throws {
        let fileManager = FileManager.default
        let scope = SecurityScope(url: url, securingAccess: securingAccess)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw NotesFileStoreError.folderMissing
        }
        guard isDirectory.boolValue else {
            throw NotesFileStoreError.notDirectory
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw NotesFileStoreError.notReadable
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            throw NotesFileStoreError.notWritable
        }
        self.folderURL = url
        self.securityScope = scope
        self.saveActor = saveActor
    }

    public init(path: String, saveActor: FileSaveActor = FileSaveActor()) throws {
        try self.init(url: URL(fileURLWithPath: path, isDirectory: true), saveActor: saveActor)
    }

    public var directoryURL: URL {
        folderURL
    }

    public func loadSnapshot(count: Int) -> [SlotRead] {
        (0..<count).map { readSlot(at: fileURL(for: $0)) }
    }

    /// A file that is there but cannot be read is not an empty note: treating it as one would show a
    /// blank slot and let the next keystroke replace the real content on disk.
    private func readSlot(at url: URL) -> SlotRead {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return .text(text)
        }
        // Gone between the check and the read is still just absent. So is a directory squatting on the
        // name: it holds no note, and the atomic write cannot replace it, so there is nothing to lose.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .missing
        }
        return .unreadable
    }

    /// Creates any slot file that is still missing. Best effort: a synced folder may be busy,
    /// and a missing file is handled by the writer anyway.
    public func ensureSlotFiles(count: Int) {
        let fileManager = FileManager.default
        for index in 0..<count {
            let url = fileURL(for: index)
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            try? Data().write(to: url, options: .atomic)
        }
    }

    public func fileURLs(count: Int) -> [URL] {
        (0..<count).map(fileURL(for:))
    }

    public func save(text: String, index: Int) async throws {
        let url = fileURL(for: index)
        guard let data = text.data(using: .utf8) else {
            throw NotesFileStoreError.writeFailed
        }
        do {
            try await saveActor.write(data: data, to: url)
        } catch {
            throw classificationOfWriteFailure()
        }
    }

    /// Writing path used when there is no time to await, such as application termination.
    public func saveSynchronously(text: String, index: Int) throws {
        let url = fileURL(for: index)
        guard let data = text.data(using: .utf8) else {
            throw NotesFileStoreError.writeFailed
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw classificationOfWriteFailure()
        }
    }

    /// A failed write only means the folder is gone when the folder really is gone; otherwise
    /// it is a transient provider hiccup that the caller should retry instead of dropping notes.
    private func classificationOfWriteFailure() -> NotesFileStoreError {
        var isDirectory: ObjCBool = false
        let path = folderURL.path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: path) else {
            return .folderMissing
        }
        return .writeFailed
    }

    public func fileURL(for index: Int) -> URL {
        folderURL.appendingPathComponent("slot\(index + 1).md")
    }
}
