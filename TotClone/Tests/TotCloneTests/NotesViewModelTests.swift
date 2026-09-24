#if canImport(XCTest)
import XCTest
@testable import TotClone

@MainActor
final class NotesViewModelTests: XCTestCase {
    func testUpdateTextPersistsSelectedSlot() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.select(index: 2)
        viewModel.updateText("latest")
        await viewModel.flushPendingSaves()

        let savedText = try String(contentsOf: folderURL.appendingPathComponent("slot3.md"), encoding: .utf8)
        XCTAssertEqual(savedText, "latest")
    }

    func testSequentialUpdatesKeepNewestValue() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("first")
        viewModel.updateText("second")
        viewModel.updateText("third")
        await viewModel.flushPendingSaves()

        let savedText = try String(contentsOf: folderURL.appendingPathComponent("slot1.md"), encoding: .utf8)
        XCTAssertEqual(savedText, "third")
    }

    func testRefreshFromDiskPicksUpExternalChanges() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("initial")
        await viewModel.flushPendingSaves()

        try "external".write(
            to: folderURL.appendingPathComponent("slot1.md"),
            atomically: true,
            encoding: .utf8
        )

        viewModel.refreshFromDisk()
        XCTAssertEqual(viewModel.slots[0].text, "external")
    }

    func testStaleDiskRevisionDoesNotClobberNewerLocalTyping() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let slotURL = folderURL.appendingPathComponent("slot1.md")
        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("hello")
        await viewModel.flushPendingSaves()

        // Typing continues while the synced folder hands back an older revision of the file.
        viewModel.updateText("hello world")
        try "hell".write(to: slotURL, atomically: true, encoding: .utf8)

        viewModel.refreshFromDisk()
        XCTAssertEqual(viewModel.slots[0].text, "hello world")

        await viewModel.flushPendingSaves()
        XCTAssertEqual(try String(contentsOf: slotURL, encoding: .utf8), "hello world")
    }

    func testTransientEmptyReadDoesNotWipeLocalNote() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let slotURL = folderURL.appendingPathComponent("slot1.md")
        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("important note")
        await viewModel.flushPendingSaves()

        try "".write(to: slotURL, atomically: true, encoding: .utf8)
        viewModel.refreshFromDisk()
        XCTAssertEqual(viewModel.slots[0].text, "important note")
    }

    func testTemporarilyMissingFileDoesNotWipeLocalNote() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("important note")
        await viewModel.flushPendingSaves()

        try FileManager.default.removeItem(at: folderURL.appendingPathComponent("slot1.md"))
        viewModel.refreshFromDisk()
        XCTAssertEqual(viewModel.slots[0].text, "important note")
    }

    func testOwnSaveEchoIsIgnoredByRefresh() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("typed locally")
        await viewModel.flushPendingSaves()

        viewModel.refreshFromDisk()
        XCTAssertEqual(viewModel.slots[0].text, "typed locally")
    }

    func testSwitchingSlotsWritesPendingTextImmediately() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("first slot")
        viewModel.select(index: 3)
        await viewModel.flushPendingSaves()

        let saved = try String(contentsOf: folderURL.appendingPathComponent("slot1.md"), encoding: .utf8)
        XCTAssertEqual(saved, "first slot")
        XCTAssertEqual(viewModel.selectedIndex, 3)
    }

    func testSynchronousFlushWritesPendingTextBeforeDebounceElapses() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        viewModel.updateText("synced")
        await viewModel.flushPendingSaves()

        viewModel.updateText("synced and then some")
        viewModel.flushPendingSaveSynchronously()

        let saved = try String(contentsOf: folderURL.appendingPathComponent("slot1.md"), encoding: .utf8)
        XCTAssertEqual(saved, "synced and then some")
    }

    func testBlockedSlotFileKeepsTextAndWritesItOnRetry() async throws {
        let folderURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let slotURL = folderURL.appendingPathComponent("slot1.md")
        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        viewModel.attachFileStore(store)
        // Something else owns the slot name right now: a directory the atomic write cannot replace.
        try FileManager.default.removeItem(at: slotURL)
        try FileManager.default.createDirectory(at: slotURL, withIntermediateDirectories: true)

        viewModel.updateText("keep me")
        await viewModel.flushPendingSaves()

        XCTAssertTrue(viewModel.isSaveFailing)
        XCTAssertEqual(viewModel.slots[0].text, "keep me")
        XCTAssertTrue(FileManager.default.fileExists(atPath: slotURL.path))

        try FileManager.default.removeItem(at: slotURL)
        await viewModel.flushPendingSaves()

        XCTAssertFalse(viewModel.isSaveFailing)
        XCTAssertEqual(try String(contentsOf: slotURL, encoding: .utf8), "keep me")
    }

    func testFatalFailureKeepsTextUntilTheSameFolderIsPickedAgain() async throws {
        let folderURL = try makeTemporaryDirectory()
        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        var reportedFatal = false
        viewModel.fileErrorHandler = { reportedFatal = true }

        viewModel.attachFileStore(store)
        viewModel.updateText("synced before the drive vanished")
        await viewModel.flushPendingSaves()

        try FileManager.default.removeItem(at: folderURL)
        viewModel.updateText("synced before the drive vanished plus more")
        await viewModel.flushPendingSaves()

        XCTAssertTrue(reportedFatal)
        XCTAssertEqual(viewModel.slots[0].text, "synced before the drive vanished plus more")

        // What the app does on a fatal error: keep the text, drop the folder handle.
        viewModel.suspendFileStore()
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        viewModel.attachFileStore(try NotesFileStore(path: folderURL.path))

        await viewModel.flushPendingSaves()
        XCTAssertEqual(
            try String(contentsOf: folderURL.appendingPathComponent("slot1.md"), encoding: .utf8),
            "synced before the drive vanished plus more"
        )
    }

    func testExplicitFolderChangeAdoptsTheNewFolderContent() async throws {
        let oldFolder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: oldFolder) }
        let newFolder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: newFolder) }

        let viewModel = NotesViewModel()
        viewModel.attachFileStore(try NotesFileStore(path: oldFolder.path))
        viewModel.updateText("typed in the old folder")
        await viewModel.flushPendingSaves()

        try "from the new folder".write(
            to: newFolder.appendingPathComponent("slot1.md"),
            atomically: true,
            encoding: .utf8
        )

        viewModel.detachFileStore()
        viewModel.attachFileStore(try NotesFileStore(path: newFolder.path))

        XCTAssertEqual(viewModel.slots[0].text, "from the new folder")
        XCTAssertEqual(
            try String(contentsOf: oldFolder.appendingPathComponent("slot1.md"), encoding: .utf8),
            "typed in the old folder"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif



