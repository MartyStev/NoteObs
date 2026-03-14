import XCTest
@testable import TotClone

@MainActor
final class NotesViewModelTests: XCTestCase {
    func testUpdateTextPersistsSelectedSlot() throws {
        let folderURL = try makeTemporaryDirectory()
        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        try viewModel.attachFileStore(store)
        viewModel.select(index: 2)
        viewModel.updateText("latest")
        viewModel.flushPendingSaves()

        let savedText = try String(contentsOf: folderURL.appendingPathComponent("slot3.md"), encoding: .utf8)
        XCTAssertEqual(savedText, "latest")
    }

    func testSequentialUpdatesKeepNewestValue() throws {
        let folderURL = try makeTemporaryDirectory()
        let store = try NotesFileStore(path: folderURL.path)
        let viewModel = NotesViewModel()

        try viewModel.attachFileStore(store)
        viewModel.updateText("first")
        viewModel.updateText("second")
        viewModel.updateText("third")
        viewModel.flushPendingSaves()

        let savedText = try String(contentsOf: folderURL.appendingPathComponent("slot1.md"), encoding: .utf8)
        XCTAssertEqual(savedText, "third")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
