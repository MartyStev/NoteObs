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

public struct NotesFileStore: Sendable {
    public let folderURL: URL
    private let saveActor: FileSaveActor

    public init(path: String, saveActor: FileSaveActor = FileSaveActor()) throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        _ = url.startAccessingSecurityScopedResource()

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
        self.saveActor = saveActor
    }

    public var directoryURL: URL {
        folderURL
    }

    public func loadSnapshot(count: Int) -> [String?] {
        let fileManager = FileManager.default
        return (0..<count).map { index in
            let url = fileURL(for: index)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
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
