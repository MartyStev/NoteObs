#if canImport(XCTest)
import XCTest
@testable import TotClone

final class NotesFileStoreTests: XCTestCase {
    func testEnsureSlotFilesCreatesMissingFilesWithoutTouchingExistingOnes() throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let existing = folderURL.appendingPathComponent("slot2.md")
        try "keep".write(to: existing, atomically: true, encoding: .utf8)

        store.ensureSlotFiles(count: 3)

        XCTAssertEqual(store.loadSnapshot(count: 3), ["", "keep", ""])
    }

    func testLoadSnapshotReportsMissingFilesAsNilAndCreatesNothing() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        try await store.save(text: "kept", index: 1)

        XCTAssertEqual(store.loadSnapshot(count: 3), [nil, "kept", nil])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("slot1.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("slot3.md").path))
    }

    func testSavePersistsContent() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        try await store.save(text: "hello world", index: 0)

        let saved = try String(contentsOf: folderURL.appendingPathComponent("slot1.md"), encoding: .utf8)
        XCTAssertEqual(saved, "hello world")
    }

    func testSaveOnUnavailableFolderIsFatal() async throws {
        let folderURL = try makeTemporaryDirectory()
        let store = try NotesFileStore(path: folderURL.path)

        try FileManager.default.removeItem(at: folderURL)

        do {
            try await store.save(text: "hello", index: 0)
            XCTFail("Expected the save to fail")
        } catch let error as NotesFileStoreError {
            XCTAssertEqual(error, .folderMissing)
            XCTAssertTrue(error.isFatal)
        }
    }

    func testSaveBlockedByOneFileIsTransientAndKeepsTheFolder() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        // A directory in the slot's place makes the write fail while the folder stays usable.
        try FileManager.default.createDirectory(
            at: folderURL.appendingPathComponent("slot1.md"),
            withIntermediateDirectories: true
        )

        do {
            try await store.save(text: "hello", index: 0)
            XCTFail("Expected the save to fail")
        } catch let error as NotesFileStoreError {
            XCTAssertEqual(error, .writeFailed)
            XCTAssertFalse(error.isFatal)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
