import Foundation

private final class SaveCoordinator {
    private let queue = DispatchQueue(label: "TotClone.NotesFileStore.saveQueue", qos: .utility)

    func enqueueWrite(data: Data, to url: URL, completion: @escaping (Result<Void, NotesFileStoreError>) -> Void) {
        queue.async {
            let result: Result<Void, NotesFileStoreError>
            do {
                try data.write(to: url, options: .atomic)
                result = .success(())
            } catch {
                result = .failure(.writeFailed)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func flush() {
        queue.sync {}
    }
}

struct NotesFileStore {
    private let folderURL: URL
    private let saveCoordinator = SaveCoordinator()

    init(path: String) throws {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
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
    }

    var directoryURL: URL {
        folderURL
    }

    func loadAll(count: Int) throws -> [String] {
        let fileManager = FileManager.default
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let url = fileURL(for: index)
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
                    throw NotesFileStoreError.writeFailed
                }
                result.append("")
                continue
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                result.append(text)
            } catch {
                throw NotesFileStoreError.readFailed
            }
        }
        return result
    }

    func fileURLs(count: Int) -> [URL] {
        (0..<count).map(fileURL(for:))
    }

    func save(
        text: String,
        index: Int,
        completion: @escaping (Result<Void, NotesFileStoreError>) -> Void
    ) {
        let url = fileURL(for: index)
        guard let data = text.data(using: .utf8) else {
            completion(.failure(.writeFailed))
            return
        }

        saveCoordinator.enqueueWrite(data: data, to: url, completion: completion)
    }

    func flushSaves() {
        saveCoordinator.flush()
    }

    func fileURL(for index: Int) -> URL {
        folderURL.appendingPathComponent("slot\(index + 1).md")
    }
}
