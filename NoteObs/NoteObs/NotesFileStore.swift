import Foundation

/// Runs slot writes one after another on a queue of their own. A write that a stalled provider
/// parks inside the kernel holds this queue, never a thread of the cooperative pool, and writes
/// land in the order they were asked for, so an older text can never overtake a newer one.
public final class FileWriteQueue: Sendable {
    private let queue = DispatchQueue(label: "NoteObs.FileWrites", qos: .userInitiated)

    public init() {}

    private static let lock = NSLock()
    nonisolated(unsafe) private static var byFolder: [String: FileWriteQueue] = [:]

    /// One queue per folder, shared by every store opened on it: reopening a folder must not let a
    /// new store's write race an old store's write to the same file. Guarded by `lock`.
    static func shared(for folderURL: URL) -> FileWriteQueue {
        let key = NotesFolderIdentity.key(for: folderURL.path)
        lock.lock()
        defer { lock.unlock() }
        if let existing = byFolder[key] { return existing }
        let created = FileWriteQueue()
        byFolder[key] = created
        return created
    }

    /// Runs `work` behind everything already queued and waits at most `timeout` for it. Answers
    /// false when the queue did not get there in time; the work still runs whenever it does.
    func performAndWait(timeout: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    public func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
    private let writeQueue: FileWriteQueue
    private let securityScope: SecurityScope

    /// Opens a folder for use. Pass a bookmark-resolved URL together with `securingAccess` so the
    /// grant the bookmark carries stays alive for as long as any copy of this store is around.
    public init(url: URL, securingAccess: Bool = false, writeQueue: FileWriteQueue? = nil) throws {
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
        self.writeQueue = writeQueue ?? FileWriteQueue.shared(for: url)
    }

    public init(path: String, writeQueue: FileWriteQueue? = nil) throws {
        try self.init(url: URL(fileURLWithPath: path, isDirectory: true), writeQueue: writeQueue)
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
        let store = self
        try await writeQueue.perform {
            try store.saveSynchronously(text: text, index: index)
        }
    }

    /// Writes several slots before the process ends, behind any write already queued for the folder,
    /// waiting at most `timeout`. Answers the slots confirmed written.
    func saveBeforeExit(_ texts: [Int: String], timeout: TimeInterval) -> [Int] {
        let store = self
        let written = ReadResult<[Int]>()
        let finished = writeQueue.performAndWait(timeout: timeout) {
            written.set(texts.compactMap { index, text in
                (try? store.saveSynchronously(text: text, index: index)) == nil ? nil : index
            })
        }
        return finished ? (written.value ?? []) : []
    }

    /// The write itself, on whatever thread calls it. The app goes through `save`, which keeps it
    /// off the main actor and the cooperative pool; termination calls this under a deadline.
    public func saveSynchronously(text: String, index: Int) throws {
        let url = fileURL(for: index)
        guard let data = text.data(using: .utf8) else {
            throw NotesFileStoreError.writeFailed
        }
        // Checked at the last moment before writing: a note that went unreadable since the folder was
        // last read is still somebody's content, and an atomic write would replace it outright.
        if readSlot(at: url) == .unreadable {
            throw NotesFileStoreError.slotUnreadable
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
