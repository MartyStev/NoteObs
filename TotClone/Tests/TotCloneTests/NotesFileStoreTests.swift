import XCTest
@testable import TotClone

final class NotesFileStoreTests: XCTestCase {
    func testLoadAllCreatesMissingFilesAndReturnsEmptySlots() throws {
        let folderURL = try makeTemporaryDirectory()
        let store = try NotesFileStore(path: folderURL.path)

        let values = try store.loadAll(count: 3)

        XCTAssertEqual(values, ["", "", ""])
        XCTAssertEqual(try String(contentsOf: folderURL.appendingPathComponent("slot1.md"), encoding: .utf8), "")
        XCTAssertEqual(try String(contentsOf: folderURL.appendingPathComponent("slot2.md"), encoding: .utf8), "")
        XCTAssertEqual(try String(contentsOf: folderURL.appendingPathComponent("slot3.md"), encoding: .utf8), "")
    }

    func testSaveReportsFailureWhenFolderBecomesUnavailable() throws {
        let folderURL = try makeTemporaryDirectory()
        let store = try NotesFileStore(path: folderURL.path)
        let expectation = expectation(description: "save failure")

        try FileManager.default.removeItem(at: folderURL)

        var receivedResult: Result<Void, NotesFileStoreError>?
        store.save(text: "hello", index: 0) { result in
            receivedResult = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
        switch receivedResult {
        case .failure(.writeFailed):
            break
        default:
            XCTFail("Expected writeFailed, got \(String(describing: receivedResult))")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
