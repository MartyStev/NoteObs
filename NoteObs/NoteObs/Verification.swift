import AppKit
import Foundation

// The scenarios below are the project's regression suite. They are deliberately kept in the app
// target instead of an XCTest file: a Command Line Tools installation has no XCTest module, so
// `swift test` reports success while running zero tests. `NoteObs --verify` runs them on any
// machine, and Tests/NoteObsTests only forwards into this list for people who do have Xcode.

public struct VerificationFailure: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public func vexpect(_ condition: @autoclosure() -> Bool, _ message: String) throws {
    if !condition() { throw VerificationFailure(message) }
}

public func vexpectEqual<T: Equatable>(
    _ actual: @autoclosure() throws -> T,
    _ expected: @autoclosure() throws -> T,
    _ message: String
) throws {
    let value = try actual()
    let target = try expected()
    if value != target { throw VerificationFailure("\(message): expected \(target), got \(value)") }
}

public struct VerificationCase: Sendable {
    public let name: String
    public let run: @MainActor () async throws -> Void

    public init(name: String, run: @escaping @MainActor () async throws -> Void) {
        self.name = name
        self.run = run
    }
}

/// A settings store that only lives inside the check, so folder-resolution scenarios leave no files
/// behind in the user's preferences.
final class InMemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }

    func string(forKey key: String) -> String? { values[key] as? String }

    func data(forKey key: String) -> Data? { values[key] as? Data }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}

enum VerificationWorkspace {
    /// Every folder a check creates carries this name, which is also how stale leftovers from an
    /// older run are recognised below.
    static let folderPrefix = "NoteObsVerify-"

    static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(folderPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Checks from before the mirror base became injectable scoped their mirrors under the user's
    /// real recovery tree, and those directories are still there. Only entries named after a check's
    /// own temporary folder go, so a mirror a real session still owes is never touched.
    static func pruneOldVerifyScopes() {
        let base = RecoveryStore.defaultDirectoryURL()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
        for name in names where name.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }

    static func slotURL(_ folder: URL, _ slot: Int) -> URL {
        folder.appendingPathComponent("slot\(slot + 1).md")
    }

    /// Bookmarks hand back `/private/var/...` where the path was stored as `/var/...`, so folder
    /// identity is compared after resolving symlinks.
    static func samePath(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as NSString).resolvingSymlinksInPath == (rhs as NSString).resolvingSymlinksInPath
    }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Mirrors are written off the main actor so typing never waits on them; the checks wait for
    /// the mirror to appear instead of assuming it already landed.
    static func waitForMirror(_ store: RecoveryStore, index: Int, timeout: TimeInterval = 3) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = store.contents(ofSlotAt: index) { return text }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    static func waitForMirrorToClear(_ store: RecoveryStore, index: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.contents(ofSlotAt: index) == nil { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Makes the folder refuse writes to one slot, the way a busy sync provider does.
    static func blockSlot(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

@MainActor
public enum NotesVerificationSuite {
    /// Building the list needs no main-actor state; only the scenario bodies do.
    nonisolated public static var cases: [VerificationCase] {
        [
            VerificationCase(name: "typing persists the selected slot") { try await testUpdateTextPersistsSelectedSlot() },
            VerificationCase(name: "sequential updates keep the newest value") { try await testSequentialUpdatesKeepNewestValue() },
            VerificationCase(name: "external edits are picked up from disk") { try await testRefreshFromDiskPicksUpExternalChanges() },
            VerificationCase(name: "a stale disk revision does not clobber newer typing") { try await testStaleDiskRevisionDoesNotClobberNewerLocalTyping() },
            VerificationCase(name: "a transient empty read does not wipe a note") { try await testTransientEmptyReadDoesNotWipeLocalNote() },
            VerificationCase(name: "a temporarily missing file does not wipe a note") { try await testTemporarilyMissingFileDoesNotWipeLocalNote() },
            VerificationCase(name: "our own save echo is ignored by the refresh") { try await testOwnSaveEchoIsIgnoredByRefresh() },
            VerificationCase(name: "switching slots writes the pending text immediately") { try await testSwitchingSlotsWritesPendingTextImmediately() },
            VerificationCase(name: "synchronous flush writes before the debounce elapses") { try await testSynchronousFlushWritesPendingTextBeforeDebounceElapses() },
            VerificationCase(name: "a blocked slot file keeps text and writes it on retry") { try await testBlockedSlotFileKeepsTextAndWritesItOnRetry() },
            VerificationCase(name: "a fatal failure keeps text until the same folder returns") { try await testFatalFailureKeepsTextUntilTheSameFolderIsPickedAgain() },
            VerificationCase(name: "an explicit folder change adopts the new folder content") { try await testExplicitFolderChangeAdoptsTheNewFolderContent() },
            VerificationCase(name: "missing slot files are created without touching existing ones") { try await testEnsureSlotFilesCreatesMissingFiles() },
            VerificationCase(name: "a missing slot file reads as absent, not empty") { try await testLoadSnapshotReportsMissingAsNil() },
            VerificationCase(name: "a write failure keeps the folder when the folder is fine") { try await testWriteFailureClassification() },
            VerificationCase(name: "text the folder never took survives a lost process") { try await testUnwrittenTextSurvivesALostProcess() },
            VerificationCase(name: "a confirmed save leaves no recovery offer") { try await testConfirmedSaveLeavesNoRecoveryOffer() },
            VerificationCase(name: "an external edit does not raise a false recovery") { try await testExternalEditDoesNotRaiseAFalseRecovery() },
            VerificationCase(name: "declining a recovery keeps the folder copy") { try await testDecliningRecoveryKeepsTheFolderCopy() },
            VerificationCase(name: "one folder's unwritten text is not offered for another") { try await testRecoveryIsScopedToItsFolder() },
            VerificationCase(name: "a read that outlasts its deadline is abandoned") { try await testAReadThatOutlastsItsDeadlineIsAbandoned() },
            VerificationCase(name: "typing with no reachable folder still lands in the mirror") { try await testTypingWithoutAReachableFolderStillLandsInTheMirror() },
            VerificationCase(name: "a watch stops even while its folder is still opening") { try await testMonitorStopsWhileASilentFolderIsBeingOpened() },
            VerificationCase(name: "the same folder under two spellings keeps one mirror") { try await testMirrorFollowsTheFolderNotItsSpelling() },
            VerificationCase(name: "typing restyles only the line it touched") { try await testStylingRescansOnlyTheTouchedLine() },
            VerificationCase(name: "a replaced document or a new font restyles everything") { try await testStylingFallsBackToAFullPass() },
            VerificationCase(name: "deleting a link removes its styling") { try await testStylingDropsARemovedLink() },
            VerificationCase(name: "splitting a line restyles the half that moved") { try await testSplittingALineRestylesTheStrandedTail() },
            VerificationCase(name: "the stored bookmark decides which folder opens") { try await testFolderResolutionPrefersTheBookmark() },
            VerificationCase(name: "folder access is released with the handle that took it") { try await testFolderAccessIsReleasedWithTheStore() },
            VerificationCase(name: "the note shortcuts are recognised once") { try await testShortcutKeysMapToSlotMoves() },
            VerificationCase(name: "settings survive a bundle identifier change") { try await testSettingsSurviveABundleIdentifierChange() },
            VerificationCase(name: "unwritten text survives the rename of the recovery directory") { try await testRecoveryDirectoryFollowsTheRename() },
            VerificationCase(name: "an unreadable slot file is reported, never read as an empty note") { try await testUnreadableSlotFileIsNotAnEmptyNote() },
            VerificationCase(name: "an unreadable slot keeps the folder closed and the file intact") { try await testUnreadableSlotIsNeverOverwritten() },
            VerificationCase(name: "a stalled switch to another folder never copies notes into it") { try await testStalledFolderSwitchDoesNotCopyNotesAcross() },
            VerificationCase(name: "retrying an unreadable folder offers typed text instead of overwriting") { try await testRetryAfterUnreadableOffersInsteadOfOverwriting() },
            VerificationCase(name: "a stalled switch after a detach never copies notes into it") { try await testStalledSwitchAfterDetachDoesNotCopyNotesAcross() },
            VerificationCase(name: "a detached folder that returns keeps its own content") { try await testDetachedFolderReturnsWithItsOwnContent() },
            VerificationCase(name: "a note going unreadable under an open folder stops all writes") { try await testNoteGoingUnreadableWhileOpenStopsWrites() },
            VerificationCase(name: "typing in one note never cancels another note's retry") { try await testTypingElsewhereKeepsAnotherSlotsRetry() },
            VerificationCase(name: "a write refuses to replace a note that will not read") { try await testWriteRefusesAnUnreadableSlot() },
            VerificationCase(name: "a snapshot read before our write landed does not undo it") { try await testSlowSnapshotDoesNotUndoALandedWrite() },
            VerificationCase(name: "quitting never waits on a write the folder does not answer") { try await testQuittingDoesNotWaitOnAStalledWrite() },
            VerificationCase(name: "typing while a folder is being read never overwrites its notes") { try await testTypingDuringTheFirstReadIsNotWritten() },
            VerificationCase(name: "re-picking the folder never pushes a clean note over a newer one") { try await testRepickingTheFolderKeepsNewerDiskContent() },
            VerificationCase(name: "typing in one note does not hide an external edit to another") { try await testRefreshAppliesSettledSlotsWhileTyping() },
            VerificationCase(name: "a checklist toggle keeps indentation and touches only the marker") { try await testChecklistToggleKeepsTheLine() },
            VerificationCase(name: "only the box of a checklist item is a toggle target") { try await testChecklistBoxIsTheOnlyTarget() }
        ]
    }

    // MARK: - Scenarios

    static func testUpdateTextPersistsSelectedSlot() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.select(index: 2)
        viewModel.updateText("latest")
        await viewModel.flushPendingSaves()

        try vexpectEqual(try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 2)), "latest", "slot3.md")
    }

    static func testSequentialUpdatesKeepNewestValue() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("first")
        viewModel.updateText("second")
        viewModel.updateText("third")
        await viewModel.flushPendingSaves()

        try vexpectEqual(try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 0)), "third", "slot1.md")
    }

    static func testRefreshFromDiskPicksUpExternalChanges() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("initial")
        await viewModel.flushPendingSaves()

        try "external".write(to: VerificationWorkspace.slotURL(folder, 0), atomically: true, encoding: .utf8)
        await viewModel.refreshFromDisk()
        try vexpectEqual(viewModel.slots[0].text, "external", "external edit adopted")
    }

    static func testStaleDiskRevisionDoesNotClobberNewerLocalTyping() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("hello")
        await viewModel.flushPendingSaves()

        // Typing continues while the synced folder hands back an older revision of the file.
        viewModel.updateText("hello world")
        try "hell".write(to: slot, atomically: true, encoding: .utf8)

        await viewModel.refreshFromDisk()
        try vexpectEqual(viewModel.slots[0].text, "hello world", "newer local typing kept")
        await viewModel.flushPendingSaves()
        try vexpectEqual(try VerificationWorkspace.read(slot), "hello world", "newer typing written back")
    }

    static func testTransientEmptyReadDoesNotWipeLocalNote() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("important note")
        await viewModel.flushPendingSaves()

        try "".write(to: slot, atomically: true, encoding: .utf8)
        await viewModel.refreshFromDisk()
        try vexpectEqual(viewModel.slots[0].text, "important note", "note survived the empty read")
    }

    static func testTemporarilyMissingFileDoesNotWipeLocalNote() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("important note")
        await viewModel.flushPendingSaves()

        try FileManager.default.removeItem(at: VerificationWorkspace.slotURL(folder, 0))
        await viewModel.refreshFromDisk()
        try vexpectEqual(viewModel.slots[0].text, "important note", "note survived the missing file")
    }

    static func testOwnSaveEchoIsIgnoredByRefresh() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("typed locally")
        await viewModel.flushPendingSaves()

        await viewModel.refreshFromDisk()
        try vexpectEqual(viewModel.slots[0].text, "typed locally", "own echo left the buffer alone")
    }

    static func testSwitchingSlotsWritesPendingTextImmediately() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("first slot")
        viewModel.select(index: 3)
        await viewModel.flushPendingSaves()

        try vexpectEqual(try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 0)), "first slot", "outgoing slot flushed")
        try vexpectEqual(viewModel.selectedIndex, 3, "selection moved")
    }

    static func testSynchronousFlushWritesPendingTextBeforeDebounceElapses() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("synced")
        await viewModel.flushPendingSaves()

        viewModel.updateText("synced and then some")
        viewModel.flushPendingSaveSynchronously()

        try vexpectEqual(try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 0)), "synced and then some", "terminating flush")
    }

    static func testBlockedSlotFileKeepsTextAndWritesItOnRetry() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        // Something else owns the slot name right now: a directory the atomic write cannot replace.
        try FileManager.default.removeItem(at: slot)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)

        viewModel.updateText("keep me")
        await viewModel.flushPendingSaves()

        try vexpect(viewModel.isSaveFailing, "the failing save is surfaced")
        try vexpectEqual(viewModel.slots[0].text, "keep me", "text kept in memory")
        try vexpect(FileManager.default.fileExists(atPath: slot.path), "the blocking entry was left alone")

        try FileManager.default.removeItem(at: slot)
        await viewModel.flushPendingSaves()

        try vexpect(!viewModel.isSaveFailing, "retry reported success")
        try vexpectEqual(try VerificationWorkspace.read(slot), "keep me", "retry wrote the text")
    }

    static func testFatalFailureKeepsTextUntilTheSameFolderIsPickedAgain() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: recoveryBase) }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        var reportedFatal = false
        viewModel.fileErrorHandler = { reportedFatal = true }

        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("synced before the drive vanished")
        await viewModel.flushPendingSaves()

        try FileManager.default.removeItem(at: folder)
        viewModel.updateText("synced before the drive vanished plus more")
        await viewModel.flushPendingSaves()

        try vexpect(reportedFatal, "the fatal error was reported")
        try vexpectEqual(viewModel.slots[0].text, "synced before the drive vanished plus more", "text kept after the folder vanished")

        // What the app does on a fatal error: keep the text, drop the folder handle.
        viewModel.suspendFileStore()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        await viewModel.flushPendingSaves()

        try vexpectEqual(
            try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 0)),
            "synced before the drive vanished plus more",
            "text written once the folder returned"
        )
        try? FileManager.default.removeItem(at: folder)
    }

    static func testExplicitFolderChangeAdoptsTheNewFolderContent() async throws {
        let oldFolder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: oldFolder) }
        let newFolder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: newFolder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: oldFolder.path))
        viewModel.updateText("typed in the old folder")
        await viewModel.flushPendingSaves()

        try "from the new folder".write(to: VerificationWorkspace.slotURL(newFolder, 0), atomically: true, encoding: .utf8)

        viewModel.detachFileStore()
        await viewModel.attachFileStore(try NotesFileStore(path: newFolder.path))

        try vexpectEqual(viewModel.slots[0].text, "from the new folder", "new folder adopted")
        try vexpectEqual(try VerificationWorkspace.read(VerificationWorkspace.slotURL(oldFolder, 0)), "typed in the old folder", "old folder untouched")
    }

    static func testEnsureSlotFilesCreatesMissingFiles() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try NotesFileStore(path: folder.path)
        try "keep".write(to: VerificationWorkspace.slotURL(folder, 1), atomically: true, encoding: .utf8)

        store.ensureSlotFiles(count: 3)

        let snapshot = store.loadSnapshot(count: 3)
        try vexpectEqual(snapshot.count, 3, "snapshot covers every slot")
        try vexpectEqual(snapshot[1], .text("keep"), "existing file untouched")
        try vexpectEqual(snapshot[0], .text(""), "missing file created empty")
        try vexpectEqual(snapshot[2], .text(""), "missing file created empty")
    }

    static func testLoadSnapshotReportsMissingAsNil() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try NotesFileStore(path: folder.path)
        try vexpectEqual(store.loadSnapshot(count: 2), [.missing, .missing], "absent slots read as missing")
        try vexpect(
            !FileManager.default.fileExists(atPath: VerificationWorkspace.slotURL(folder, 0).path),
            "reading created nothing"
        )
    }

    static func testWriteFailureClassification() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let slot = VerificationWorkspace.slotURL(folder, 0)

        let store = try NotesFileStore(path: folder.path)
        // The folder is healthy but the slot name is taken: transient, the caller should retry.
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        do {
            try await store.save(text: "x", index: 0)
            throw VerificationFailure("blocked write should have failed")
        } catch let error as NotesFileStoreError {
            try vexpectEqual(error, .writeFailed, "blocked slot is a transient failure")
            try vexpect(!error.isFatal, "transient failure keeps the folder attached")
        }
        try FileManager.default.removeItem(at: slot)

        // A folder that is really gone must not be treated as a transient hiccup.
        try FileManager.default.removeItem(at: folder)
        do {
            try store.saveSynchronously(text: "x", index: 0)
            throw VerificationFailure("write into a missing folder should have failed")
        } catch let error as NotesFileStoreError {
            try vexpectEqual(error, .folderMissing, "missing folder is fatal")
            try vexpect(error.isFatal, "fatal failure is reported as such")
        }
    }

    // MARK: - Recovery from a session that died with a write owed

    static func testUnwrittenTextSurvivesALostProcess() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)

        // One view model, one typing session, and the folder stops accepting writes mid-save.
        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        try VerificationWorkspace.blockSlot(VerificationWorkspace.slotURL(folder, 0))
        viewModel.updateText("typed while the folder was busy")
        await viewModel.flushPendingSaves()

        try vexpectEqual(
            VerificationWorkspace.waitForMirror(mirrors, index: 0),
            "typed while the folder was busy",
            "the text was mirrored outside the folder"
        )
        viewModel.suspendFileStore()  // stand in for the process going away

        // A fresh session opens the same folder: the mirror is offered, not silently applied.
        let relaunched = NotesViewModel(recoveryBase: recoveryBase)
        await relaunched.attachFileStore(try NotesFileStore(path: folder.path))
        try vexpectEqual(relaunched.recoveryOffers.count, 1, "one recovery offer")
        try vexpectEqual(relaunched.recoveryOffers.first?.text, "typed while the folder was busy", "the offer carries the text")
        try vexpectEqual(relaunched.slots[0].text, "", "the note still shows the folder until the user chooses")

        try FileManager.default.removeItem(at: VerificationWorkspace.slotURL(folder, 0))
        guard let offer = relaunched.recoveryOffers.first else { throw VerificationFailure("offer disappeared") }
        relaunched.acceptRecovery(offer)
        await relaunched.flushPendingSaves()

        try vexpectEqual(relaunched.slots[0].text, "typed while the folder was busy", "accepted text reaches the note")
        try vexpectEqual(
            try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 0)),
            "typed while the folder was busy",
            "accepted text reaches the folder"
        )
        try vexpect(
            VerificationWorkspace.waitForMirrorToClear(mirrors, index: 0),
            "the mirror is cleared once the folder has the text"
        )
        try vexpect(relaunched.recoveryOffers.isEmpty, "the offer list drains after accepting")
    }

    static func testConfirmedSaveLeavesNoRecoveryOffer() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("written and confirmed")
        await viewModel.flushPendingSaves()

        try vexpect(
            VerificationWorkspace.waitForMirrorToClear(mirrors, index: 0),
            "a confirmed save clears its mirror"
        )

        let relaunched = NotesViewModel(recoveryBase: recoveryBase)
        await relaunched.attachFileStore(try NotesFileStore(path: folder.path))
        try vexpect(relaunched.recoveryOffers.isEmpty, "nothing to recover after a clean save")
        try vexpectEqual(relaunched.slots[0].text, "written and confirmed", "the note came from the folder")
    }

    static func testExternalEditDoesNotRaiseAFalseRecovery() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("saved here first")
        await viewModel.flushPendingSaves()

        // The note is edited elsewhere (Obsidian on another device) and we relaunch.
        try "edited outside the app".write(
            to: VerificationWorkspace.slotURL(folder, 0),
            atomically: true,
            encoding: .utf8
        )

        let relaunched = NotesViewModel(recoveryBase: recoveryBase)
        await relaunched.attachFileStore(try NotesFileStore(path: folder.path))
        try vexpect(relaunched.recoveryOffers.isEmpty, "an external edit is not a lost write")
        try vexpectEqual(relaunched.slots[0].text, "edited outside the app", "the folder copy is adopted")
    }

    static func testDecliningRecoveryKeepsTheFolderCopy() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)
        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        try VerificationWorkspace.blockSlot(slot)
        viewModel.updateText("draft that never landed")
        await viewModel.flushPendingSaves()
        try vexpect(VerificationWorkspace.waitForMirror(mirrors, index: 0) != nil, "draft mirrored")
        viewModel.suspendFileStore()

        // Meanwhile the folder gets its own revision of the note from elsewhere.
        try FileManager.default.removeItem(at: slot)
        try "folder version".write(to: slot, atomically: true, encoding: .utf8)

        let relaunched = NotesViewModel(recoveryBase: recoveryBase)
        await relaunched.attachFileStore(try NotesFileStore(path: folder.path))
        guard let offer = relaunched.recoveryOffers.first else { throw VerificationFailure("no offer to decline") }
        relaunched.declineRecovery(offer)

        try vexpect(
            VerificationWorkspace.waitForMirrorToClear(mirrors, index: 0),
            "declining drops the mirror"
        )
        try vexpectEqual(try VerificationWorkspace.read(slot), "folder version", "the folder copy was left alone")
        try vexpectEqual(relaunched.recoveryOffers.count, 0, "the offer is gone")
    }

    static func testRecoveryIsScopedToItsFolder() async throws {
        let owedFolder = try VerificationWorkspace.makeFolder()
        let otherFolder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: owedFolder)
            try? FileManager.default.removeItem(at: otherFolder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: owedFolder.path))
        try VerificationWorkspace.blockSlot(VerificationWorkspace.slotURL(owedFolder, 0))
        viewModel.updateText("owed to the first folder")
        await viewModel.flushPendingSaves()
        viewModel.suspendFileStore()

        // Opening a different folder must not surface another folder's unwritten text.
        let other = NotesViewModel(recoveryBase: recoveryBase)
        await other.attachFileStore(try NotesFileStore(path: otherFolder.path))
        try vexpect(other.recoveryOffers.isEmpty, "no offers from an unrelated folder")
        try vexpectEqual(other.slots[0].text, "", "the new folder starts empty")
    }

    /// A folder macOS is still asking about answers nothing at all: the read sits in the kernel for
    /// the life of the process. This is the waiting rule the app uses on such a folder — it gives up
    /// on the read, keeps working, and never picks the abandoned answer back up.
    static func testAReadThatOutlastsItsDeadlineIsAbandoned() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "on the folder".write(to: VerificationWorkspace.slotURL(folder, 0), atomically: true, encoding: .utf8)
        let store = try NotesFileStore(path: folder.path)

        let finished = ReadResult<Bool>()
        let began = Date()
        let outcome: [SlotRead]? = await NotesViewModel.readWithinDeadline(deadlineNanoseconds: 150_000_000) {
            Thread.sleep(forTimeInterval: 0.6)
            let texts = store.loadSnapshot(count: 1)
            finished.set(true)
            return texts
        }
        let elapsed = Date().timeIntervalSince(began)
        try vexpect(outcome == nil, "a read that outlasts its deadline brings nothing to the app")
        try vexpect(elapsed < 0.5, "the wait gave up at its deadline, not after \(elapsed)s")

        let deadline = Date().addingTimeInterval(3)
        while finished.value != true, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try vexpectEqual(finished.value, true, "the abandoned read did finish, out of the app's way")

        // A lost read must not take the folder with it: reads run beside each other, not behind.
        let next = await NotesViewModel.readWithinDeadline(deadlineNanoseconds: 200_000_000) {
            store.loadSnapshot(count: 1)
        }
        try vexpectEqual(next?.first, .text("on the folder"), "the next read of the same folder is not held up")
    }

    static func testTypingWithoutAReachableFolderStillLandsInTheMirror() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        // What a stall or a fatal folder error leaves behind: no store, but the folder remembered.
        viewModel.suspendFileStore()

        let typed = "typed while the folder was out of reach"
        viewModel.select(index: 1)
        viewModel.updateText(typed)
        try await Task.sleep(nanoseconds: 1_000_000_000)   // outlast the debounce: nothing may be saved

        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)
        try vexpectEqual(mirrors.contents(ofSlotAt: 1), typed, "the note is held outside the folder")
        try vexpectEqual(
            VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 1)),
            "",
            "but the note did not reach the folder that cannot be written"
        )

        // Text the folder never took is offered back to the session that opens it next.
        mirrors.mirror(text: "left over from the lost session", index: 2)
        mirrors.settle()

        let relaunched = NotesViewModel(recoveryBase: recoveryBase)
        await relaunched.attachFileStore(try NotesFileStore(path: folder.path))
        try vexpectEqual(relaunched.recoveryOffers.count, 2, "both unwritten notes come back as offers")
        try vexpectEqual(relaunched.recoveryOffers.last?.text, "left over from the lost session", "the offer holds the note")
    }

    /// Watching a folder means opening it, and an open() on a folder the system is still thinking
    /// about never comes back. Stopping the watch is what the app does next — switch folders,
    /// quit — so it has to work without waiting for that open.
    static func testMonitorStopsWhileASilentFolderIsBeingOpened() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let slot = VerificationWorkspace.slotURL(folder, 0)
        guard mkfifo(slot.path, 0o644) == 0 else {
            throw VerificationFailure("a named pipe could not stand in for a silent folder")
        }

        let monitor = NotesExternalChangeMonitor(directoryURL: folder, fileURLs: [slot]) {}
        monitor.start()
        // Let the install reach the open() on the pipe and stay there.
        try? await Task.sleep(nanoseconds: 250_000_000)
        try vexpect(monitor.isStarted, "the watch is running")

        let began = Date()
        monitor.stop()
        let elapsed = Date().timeIntervalSince(began)
        try vexpect(elapsed < 0.5, "stopping waited \(elapsed)s for a parked open()")
        try vexpect(!monitor.isStarted, "the watch is off")

        try? FileManager.default.removeItem(at: slot)
    }

    static func testMirrorFollowsTheFolderNotItsSpelling() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }

        let asOpened = "/private\(folder.path)"
        try vexpect(
            FileManager.default.fileExists(atPath: asOpened),
            "the temporary folder really is reachable through its other spelling"
        )
        try vexpectEqual(
            NotesFolderIdentity.key(for: folder.path),
            NotesFolderIdentity.key(for: asOpened),
            "one folder means one identity"
        )

        let writtenThrough = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)
        writtenThrough.mirror(text: "owed across the rename", index: 0)
        writtenThrough.settle()

        let readThrough = RecoveryStore(baseDirectory: recoveryBase).scoped(to: asOpened)
        try vexpectEqual(
            readThrough.contents(ofSlotAt: 0),
            "owed across the rename",
            "a mirror survives the folder being named differently"
        )
    }

    static func testStylingRescansOnlyTheTouchedLine() async throws {
        let font = NSFont.systemFont(ofSize: 13)
        let original = "open https://one.example now\na line being typed" as NSString
        var tracker = MarkdownStylingTracker()

        guard let first = tracker.rangeToRestyle(in: original, font: font, forcingFullPass: false) else {
            throw VerificationFailure("a non-empty document needs a styling pass")
        }
        try vexpectEqual(first.length, original.length, "the first pass covers the whole document")

        let typed = "open https://one.example now\na line being typed!" as NSString
        guard let second = tracker.rangeToRestyle(in: typed, font: font, forcingFullPass: false) else {
            throw VerificationFailure("typing needs a styling pass")
        }
        let link = NSRange(location: 5, length: 19)  // "https://one.example"
        try vexpectEqual(second.location, original.range(of: "a line").location, "restyling starts on the edited line")
        try vexpect(second.length < typed.length, "restyling stops before the rest of the document")
        try vexpect(second.location > NSMaxRange(link), "the untouched line is not rescanned")

        let links = MarkdownStyling.linkRanges(in: typed, scanning: NSRange(location: 0, length: typed.length))
        try vexpectEqual(links.count, 1, "the URL is detected as a link")
        try vexpectEqual(MarkdownStyling.linkRanges(in: typed, scanning: second).count, 0, "the edited line holds no URL")
    }

    static func testStylingFallsBackToAFullPass() async throws {
        let font = NSFont.systemFont(ofSize: 13)
        let line = String(repeating: "a", count: MarkdownStyling.fullPassChangeThreshold + 1_000) as NSString
        var tracker = MarkdownStylingTracker()
        _ = tracker.rangeToRestyle(in: line, font: font, forcingFullPass: false)

        let rewritten = (String(repeating: "a", count: 2_500) + String(repeating: "b", count: line.length - 2_500)) as NSString
        guard let oversized = tracker.rangeToRestyle(in: rewritten, font: font, forcingFullPass: false) else {
            throw VerificationFailure("an oversized change needs a styling pass")
        }
        try vexpectEqual(oversized.length, rewritten.length, "a change bigger than a line restyles the document")

        var fontTracker = MarkdownStylingTracker()
        let short = "hello" as NSString
        _ = fontTracker.rangeToRestyle(in: short, font: font, forcingFullPass: false)
        let longer = "hello!" as NSString
        guard let afterFontChange = fontTracker.rangeToRestyle(in: longer, font: NSFont.systemFont(ofSize: 17), forcingFullPass: false) else {
            throw VerificationFailure("a font change needs a styling pass")
        }
        try vexpectEqual(afterFontChange.length, longer.length, "a new font restyles every character")

        var forced = MarkdownStylingTracker()
        _ = forced.rangeToRestyle(in: short, font: font, forcingFullPass: false)
        guard let explicit = forced.rangeToRestyle(in: longer, font: font, forcingFullPass: true) else {
            throw VerificationFailure("an explicit pass needs styling")
        }
        try vexpectEqual(explicit.length, longer.length, "a replaced buffer restyles the document")
    }

    static func testStylingDropsARemovedLink() async throws {
        let text = NSMutableAttributedString(string: "see example.com here")
        text.setAttributes(
            [.link: URL(string: "https://example.com")!, .underlineStyle: NSUnderlineStyle.single.rawValue],
            range: NSRange(location: 4, length: 11)
        )
        let storage = NSTextStorage(attributedString: text)
        let current = storage.string as NSString
        MarkdownStyling.applyStyling(
            to: storage,
            text: current,
            target: NSRange(location: 0, length: current.length),
            font: NSFont.systemFont(ofSize: 13),
            color: .labelColor
        )

        try vexpect(storage.attribute(.link, at: 4, effectiveRange: nil) == nil, "a link attribute with no URL behind it is cleared")
        try vexpect(storage.attribute(.underlineStyle, at: 4, effectiveRange: nil) == nil, "the underline goes with it")

        let withURL = "see https://example.com here" as NSString
        let restored = NSTextStorage(string: withURL as String)
        MarkdownStyling.applyStyling(
            to: restored,
            text: withURL,
            target: NSRange(location: 0, length: withURL.length),
            font: NSFont.systemFont(ofSize: 13),
            color: .labelColor
        )
        try vexpect(restored.attribute(.link, at: withURL.range(of: "https://").location, effectiveRange: nil) != nil, "a URL becomes a link")
    }

    static func testSplittingALineRestylesTheStrandedTail() async throws {
        let font = NSFont.systemFont(ofSize: 13)
        let before = "read https://example.com/docs now" as NSString
        let storage = NSTextStorage(string: before as String)
        var tracker = MarkdownStylingTracker()

        func restyle(_ text: NSString) {
            guard let target = tracker.rangeToRestyle(in: text, font: font, forcingFullPass: false) else { return }
            MarkdownStyling.applyStyling(
                to: storage,
                text: text,
                target: target,
                font: font,
                color: .labelColor
            )
        }

        restyle(before)
        let head = before.range(of: "https://").location
        try vexpect(storage.attribute(.link, at: head, effectiveRange: nil) != nil, "the whole URL starts out a link")

        // The Enter key lands inside the URL; the editor carries the attributes of that run across.
        let split = head + "https://example".count
        let after = "read https://example.com\n/docs now" as NSString
        storage.replaceCharacters(in: NSRange(location: split, length: 0), with: "\n")
        try vexpect(
            storage.attribute(.link, at: after.range(of: "/docs").location, effectiveRange: nil) != nil,
            "the tail keeps the link it was written with"
        )

        restyle(after)
        let tail = after.range(of: "/docs").location
        try vexpect(storage.attribute(.link, at: tail, effectiveRange: nil) == nil, "the stranded tail loses the link")
        try vexpect(storage.attribute(.underlineStyle, at: tail, effectiveRange: nil) == nil, "and the underline with it")
        try vexpect(storage.attribute(.link, at: head, effectiveRange: nil) != nil, "the line that kept a URL is still a link")
    }

    static func testFolderResolutionPrefersTheBookmark() async throws {
        let store = InMemorySettingsStore()
        let pathKey = "notesFolderPath"
        let bookmarkKey = "notesFolderBookmark"
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let picked = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: picked) }

        func resolvedPath() -> String? {
            NotesFolderResolver.folderURL(store: store, pathKey: pathKey, bookmarkKey: bookmarkKey)?.path
        }

        store.set(folder.path, forKey: pathKey)
        try vexpect(VerificationWorkspace.samePath(resolvedPath(), folder.path), "a setup with only a path still resolves")
        NotesFolderResolver.storeBookmark(for: picked, store: store, pathKey: pathKey, bookmarkKey: bookmarkKey)
        try vexpect(NotesFolderResolver.bookmarkData(for: picked) != nil, "a folder can be turned into a bookmark")
        try vexpect(VerificationWorkspace.samePath(resolvedPath(), picked.path), "the bookmark decides which folder opens")
        try vexpect(VerificationWorkspace.samePath(store.string(forKey: pathKey), picked.path), "the path follows the bookmark")

        // An unreadable bookmark must not cost the user their folder.
        store.set(folder.path, forKey: pathKey)
        store.set(Data([0x00, 0x01, 0x02]), forKey: bookmarkKey)
        try vexpect(VerificationWorkspace.samePath(resolvedPath(), folder.path), "a broken bookmark falls back to the path")

        NotesFolderResolver.storeBookmark(for: picked, store: store, pathKey: pathKey, bookmarkKey: bookmarkKey)
        store.set(folder.path, forKey: pathKey)
        try FileManager.default.removeItem(at: picked)
        try vexpect(VerificationWorkspace.samePath(resolvedPath(), folder.path), "a bookmark to a folder that is gone falls back to the path")

        store.set(nil, forKey: pathKey)
        store.set(nil, forKey: bookmarkKey)
        try vexpect(resolvedPath() == nil, "nothing stored means no folder")
    }

    static func testFolderAccessIsReleasedWithTheStore() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try vexpect(!SecurityScope(url: folder, securingAccess: false).isGranted, "no request means no grant")

        do {
            // Both of these ask for a scope the system may or may not hand out for a plain path;
            // what must never happen is an unbalanced release once they go out of scope.
            let store = try NotesFileStore(url: folder, securingAccess: true)
            try store.saveSynchronously(text: "written while access was held", index: 0)
        }
        try vexpectEqual(
            try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 0)),
            "written while access was held",
            "dropping the handle leaves the note in the folder"
        )

        let reopened = try NotesFileStore(url: folder, securingAccess: true)
        try reopened.saveSynchronously(text: "written again", index: 0)
        try vexpectEqual(
            try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 0)),
            "written again",
            "the folder opens again after the previous handle was released"
        )
    }

    static func testShortcutKeysMapToSlotMoves() async throws {
        func keyDown(_ modifiers: NSEvent.ModifierFlags, _ keyCode: UInt16, _ characters: String) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else {
                throw VerificationFailure("the check could not build a key event")
            }
            return event
        }

        // Real arrow keys arrive with .numericPad and .function set; the shortcuts must still match.
        let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]
        let cmdOptionLeft = try keyDown(arrowFlags.union([.command, .option]), 123, "\u{F702}")
        let cmdOptionRight = try keyDown(arrowFlags.union([.command, .option]), 124, "\u{F703}")
        let cmdLeft = try keyDown(arrowFlags.union(.command), 123, "\u{F702}")
        let cmdThree = try keyDown(.command, 20, "3")
        let cmdNine = try keyDown(.command, 24, "9")
        let cmdShiftOptionRight = try keyDown(arrowFlags.union([.command, .option, .shift]), 124, "\u{F703}")
        let plainLetter = try keyDown([], 0, "a")

        try vexpect(CapturedKey(event: cmdOptionLeft) == .left, "Cmd+Option+Left walks to the previous note")
        try vexpect(CapturedKey(event: cmdOptionRight) == .right, "Cmd+Option+Right walks to the next note")
        try vexpect(CapturedKey(event: cmdLeft) == nil, "Cmd+Left stays with the editor: start of the line")
        try vexpect(CapturedKey(event: cmdThree) == .slot(2), "Cmd+3 jumps to the third note")
        try vexpect(CapturedKey(event: cmdNine) == nil, "a digit without a note behind it is left alone")
        try vexpect(CapturedKey(event: cmdShiftOptionRight) == nil, "selection chords are not note shortcuts")
        try vexpect(CapturedKey(event: plainLetter) == nil, "plain typing reaches the editor")
    }

    static func testSettingsSurviveABundleIdentifierChange() async throws {
        let legacy = InMemorySettingsStore()
        let current = InMemorySettingsStore()
        legacy.set("/Users/someone/notes", forKey: "notesFolderPath")
        legacy.set(0.15, forKey: "backgroundOpacity")
        legacy.set(true, forKey: "launchAtLoginEnabled")

        let moved = SettingsIdentityMigration.migrate(
            keys: ["notesFolderPath", "backgroundOpacity", "blurMaterial"],
            from: [legacy],
            to: current
        )
        try vexpectEqual(moved.count, 2, "only the settings that exist are moved")
        try vexpectEqual(current.string(forKey: "notesFolderPath"), "/Users/someone/notes", "the notes folder survives the move")
        try vexpect(current.object(forKey: "blurMaterial") == nil, "a setting nobody saved stays absent")

        // A choice made after the move must not be undone by the next launch.
        current.set(0.9, forKey: "backgroundOpacity")
        let again = SettingsIdentityMigration.migrate(
            keys: ["notesFolderPath", "backgroundOpacity"],
            from: [legacy],
            to: current
        )
        try vexpectEqual(again, [], "a second pass moves nothing")
        try vexpectEqual(current.object(forKey: "backgroundOpacity") as? Double, 0.9, "the newer value wins")
    }

    static func testUnreadableSlotFileIsNotAnEmptyNote() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try "readable".write(to: VerificationWorkspace.slotURL(folder, 0), atomically: true, encoding: .utf8)
        // Not valid UTF-8: the file is there, the text is not recoverable by this reader.
        try Data([0xFF, 0xFE, 0x80]).write(to: VerificationWorkspace.slotURL(folder, 1))
        // A directory squatting on the name holds no note and cannot be replaced by a write either.
        try FileManager.default.createDirectory(at: VerificationWorkspace.slotURL(folder, 2), withIntermediateDirectories: true)

        let store = try NotesFileStore(path: folder.path)
        try vexpectEqual(
            store.loadSnapshot(count: 4),
            [.text("readable"), .unreadable, .missing, .missing],
            "a file that exists but will not read is never mistaken for an absent one"
        )
    }

    static func testUnreadableSlotIsNeverOverwritten() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let original = Data([0xFF, 0xFE, 0x80])
        let unreadableSlot = VerificationWorkspace.slotURL(folder, 1)
        try "fine".write(to: VerificationWorkspace.slotURL(folder, 0), atomically: true, encoding: .utf8)
        try original.write(to: unreadableSlot)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        var reported: [Int] = []
        viewModel.folderUnreadableHandler = { reported = $0 }
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))

        try vexpectEqual(reported, [1], "the unreadable slot is reported")

        viewModel.select(index: 1)
        viewModel.updateText("typed over a file nobody could read")
        try await Task.sleep(nanoseconds: 1_000_000_000)   // outlast the debounce
        await viewModel.flushPendingSaves()

        try vexpectEqual(try Data(contentsOf: unreadableSlot), original, "the unreadable file was not replaced")
        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)
        try vexpectEqual(
            mirrors.contents(ofSlotAt: 1),
            "typed over a file nobody could read",
            "what was typed is still kept outside the folder"
        )

        // Once the file is readable again, a session that opens the folder shows it, not a blank note.
        try "repaired".write(to: unreadableSlot, atomically: true, encoding: .utf8)
        let nextRecoveryBase = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: nextRecoveryBase) }
        let next = NotesViewModel(recoveryBase: nextRecoveryBase)
        var reportedAgain: [Int] = []
        next.folderUnreadableHandler = { reportedAgain = $0 }
        await next.attachFileStore(try NotesFileStore(path: folder.path))
        try vexpectEqual(reportedAgain, [], "a readable folder opens normally")
        try vexpectEqual(next.slots[1].text, "repaired", "the repaired note is shown as it is")
    }

    static func testStalledFolderSwitchDoesNotCopyNotesAcross() async throws {
        let folderA = try VerificationWorkspace.makeFolder()
        let folderB = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slotA = VerificationWorkspace.slotURL(folderA, 0)
        let slotB = VerificationWorkspace.slotURL(folderB, 0)
        try "notes of A".write(to: slotA, atomically: true, encoding: .utf8)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase, readTimeout: 200_000_000)
        var stalls = 0
        viewModel.folderStalledHandler = { stalls += 1 }
        await viewModel.attachFileStore(try NotesFileStore(path: folderA.path))
        try vexpectEqual(viewModel.slots[0].text, "notes of A", "folder A is open")

        // Folder B does not answer: its first read outlasts the deadline, as a permission stall does.
        try "notes of B".write(to: slotB, atomically: true, encoding: .utf8)
        let answeredLate = ReadResult<Bool>()
        viewModel.snapshotReader = { store, count in
            if answeredLate.value == nil {
                answeredLate.set(true)
                Thread.sleep(forTimeInterval: 0.8)
            }
            return store.loadSnapshot(count: count)
        }
        await viewModel.attachFileStore(try NotesFileStore(path: folderB.path))
        try vexpectEqual(stalls, 1, "the silent folder is reported as stalled")
        try vexpectEqual(viewModel.slots[0].text, "", "A's notes are not left standing in front of folder B")

        // Access arrives and the user picks the folder again.
        await viewModel.attachFileStore(try NotesFileStore(path: folderB.path))
        await viewModel.flushPendingSaves()

        try vexpectEqual(viewModel.slots[0].text, "notes of B", "folder B shows its own notes")
        try vexpectEqual(try VerificationWorkspace.read(slotB), "notes of B", "A's notes were not written into folder B")
        try vexpectEqual(try VerificationWorkspace.read(slotA), "notes of A", "folder A is untouched")
    }

    static func testRetryAfterUnreadableOffersInsteadOfOverwriting() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let readableSlot = VerificationWorkspace.slotURL(folder, 0)
        let unreadableSlot = VerificationWorkspace.slotURL(folder, 1)
        try "the real note".write(to: readableSlot, atomically: true, encoding: .utf8)
        try Data([0xFF, 0xFE, 0x80]).write(to: unreadableSlot)
        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        var reported: [Int] = []
        viewModel.folderUnreadableHandler = { reported = $0 }
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        try vexpectEqual(reported, [1], "the folder stayed closed")
        try vexpectEqual(viewModel.slots[0].text, "", "the real note never loaded")

        // The user types into slots that look empty: one holds a note on disk, one really is empty.
        viewModel.updateText("typed over what looked empty")
        viewModel.select(index: 2)
        viewModel.updateText("typed into an empty slot")
        try vexpectEqual(VerificationWorkspace.waitForMirror(mirrors, index: 0), "typed over what looked empty", "slot 1 mirrored")
        try vexpectEqual(VerificationWorkspace.waitForMirror(mirrors, index: 2), "typed into an empty slot", "slot 3 mirrored")

        // Sync delivers the file and the user presses "Повторить" on the same session.
        try "repaired".write(to: unreadableSlot, atomically: true, encoding: .utf8)
        reported = []
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        await viewModel.flushPendingSaves()

        try vexpectEqual(reported, [], "the folder opens once every slot reads")
        try vexpectEqual(try VerificationWorkspace.read(readableSlot), "the real note", "the note on disk was not overwritten")
        try vexpectEqual(viewModel.slots[0].text, "the real note", "the note shows what the folder holds")
        try vexpectEqual(viewModel.slots[1].text, "repaired", "the repaired note is shown")
        try vexpectEqual(
            viewModel.recoveryOffers,
            [RecoveryOffer(index: 0, text: "typed over what looked empty")],
            "the typed text is offered back, not lost and not applied"
        )
        try vexpectEqual(
            try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 2)),
            "typed into an empty slot",
            "text typed into a slot that is empty on disk still reaches the folder"
        )

        // Accepting is the user's decision to replace the note.
        guard let offer = viewModel.recoveryOffers.first else { throw VerificationFailure("no offer to accept") }
        viewModel.acceptRecovery(offer)
        await viewModel.flushPendingSaves()
        try vexpectEqual(try VerificationWorkspace.read(readableSlot), "typed over what looked empty", "accepted text reaches the folder")
    }

    static func testStalledSwitchAfterDetachDoesNotCopyNotesAcross() async throws {
        let folderA = try VerificationWorkspace.makeFolder()
        let folderB = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folderA)
            try? FileManager.default.removeItem(at: folderB)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slotA = VerificationWorkspace.slotURL(folderA, 0)
        let slotB = VerificationWorkspace.slotURL(folderB, 0)
        try "notes of A".write(to: slotA, atomically: true, encoding: .utf8)
        try "notes of B".write(to: slotB, atomically: true, encoding: .utf8)
        let mirrorsB = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folderB.path)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase, readTimeout: 200_000_000)
        await viewModel.attachFileStore(try NotesFileStore(path: folderA.path))
        try vexpectEqual(viewModel.slots[0].text, "notes of A", "folder A is open")

        // What the app does when the configured folder cannot be opened at all.
        viewModel.detachFileStore()

        let answeredLate = ReadResult<Bool>()
        viewModel.snapshotReader = { store, count in
            if answeredLate.value == nil {
                answeredLate.set(true)
                Thread.sleep(forTimeInterval: 0.8)
            }
            return store.loadSnapshot(count: count)
        }
        var stalls = 0
        viewModel.folderStalledHandler = { stalls += 1 }
        await viewModel.attachFileStore(try NotesFileStore(path: folderB.path))
        try vexpectEqual(stalls, 1, "folder B is reported as stalled")
        try vexpectEqual(viewModel.slots[0].text, "", "A's notes are not shown in front of folder B")

        viewModel.updateText("typed while B was silent")
        try vexpectEqual(VerificationWorkspace.waitForMirror(mirrorsB, index: 0), "typed while B was silent", "typing is kept")

        await viewModel.attachFileStore(try NotesFileStore(path: folderB.path))
        await viewModel.flushPendingSaves()

        try vexpectEqual(try VerificationWorkspace.read(slotB), "notes of B", "B's note was not overwritten")
        try vexpectEqual(try VerificationWorkspace.read(slotA), "notes of A", "folder A is untouched")
        try vexpectEqual(viewModel.slots[0].text, "notes of B", "folder B shows its own note")
        try vexpectEqual(
            viewModel.recoveryOffers,
            [RecoveryOffer(index: 0, text: "typed while B was silent")],
            "what was typed during the stall is offered back"
        )
    }

    static func testDetachedFolderReturnsWithItsOwnContent() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("saved before the detach")
        await viewModel.flushPendingSaves()
        try vexpectEqual(try VerificationWorkspace.read(slot), "saved before the detach", "the save landed")

        viewModel.detachFileStore()
        try "edited elsewhere while detached".write(to: slot, atomically: true, encoding: .utf8)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        await viewModel.flushPendingSaves()

        try vexpectEqual(viewModel.slots[0].text, "edited elsewhere while detached", "the folder's own content wins")
        try vexpectEqual(try VerificationWorkspace.read(slot), "edited elsewhere while detached", "the external edit was not overwritten")
    }

    static func testNoteGoingUnreadableWhileOpenStopsWrites() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let firstSlot = VerificationWorkspace.slotURL(folder, 0)
        let secondSlot = VerificationWorkspace.slotURL(folder, 1)
        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)

        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        var reported: [Int] = []
        viewModel.folderUnreadableHandler = { reported = $0 }
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("saved while the folder was healthy")
        await viewModel.flushPendingSaves()

        // Another tool leaves the second note in a state this app cannot read.
        let corrupted = Data([0xFF, 0xFE, 0x80])
        try corrupted.write(to: secondSlot)
        await viewModel.refreshFromDisk()
        try vexpectEqual(reported, [1], "the unreadable note is reported")

        viewModel.select(index: 1)
        viewModel.updateText("edited after the file went bad")
        try await Task.sleep(nanoseconds: 1_000_000_000)   // outlast the debounce
        await viewModel.flushPendingSaves()
        try vexpectEqual(try Data(contentsOf: secondSlot), corrupted, "the unreadable file was not replaced")
        try vexpectEqual(VerificationWorkspace.waitForMirror(mirrors, index: 1), "edited after the file went bad", "the edit is kept")

        // The file is repaired and the user retries on the same session.
        try "repaired by hand".write(to: secondSlot, atomically: true, encoding: .utf8)
        reported = []
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        await viewModel.flushPendingSaves()

        try vexpectEqual(reported, [], "the folder opens again")
        try vexpectEqual(try VerificationWorkspace.read(secondSlot), "repaired by hand", "the repair was not overwritten")
        try vexpectEqual(viewModel.slots[1].text, "repaired by hand", "the repaired note is shown")
        try vexpectEqual(
            viewModel.recoveryOffers,
            [RecoveryOffer(index: 1, text: "edited after the file went bad")],
            "the edit is offered back"
        )
        try vexpectEqual(try VerificationWorkspace.read(firstSlot), "saved while the folder was healthy", "the healthy note is intact")
        try vexpectEqual(viewModel.slots[0].text, "saved while the folder was healthy", "and still shown")
    }

    static func testTypingElsewhereKeepsAnotherSlotsRetry() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let firstSlot = VerificationWorkspace.slotURL(folder, 0)
        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))

        try VerificationWorkspace.blockSlot(firstSlot)
        viewModel.updateText("first note, waiting for its retry")
        await viewModel.flushPendingSaves()
        try vexpect(viewModel.isSaveFailing, "the first note's write failed and is being retried")

        // The user moves on and types in another note while the first one is still owed.
        viewModel.select(index: 1)
        viewModel.updateText("second note")
        await viewModel.flushPendingSaves()
        try vexpectEqual(
            try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 1)),
            "second note",
            "the second note is written"
        )

        try FileManager.default.removeItem(at: firstSlot)
        let deadline = Date().addingTimeInterval(8)
        while (try? VerificationWorkspace.read(firstSlot)) != "first note, waiting for its retry", Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try vexpectEqual(
            try VerificationWorkspace.read(firstSlot),
            "first note, waiting for its retry",
            "the first note's retry survived the typing in another note"
        )
        try vexpect(!viewModel.isSaveFailing, "no write is failing any more")
    }

    static func testWriteRefusesAnUnreadableSlot() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let slot = VerificationWorkspace.slotURL(folder, 0)
        let unreadable = Data([0xFF, 0xFE, 0x80])
        try unreadable.write(to: slot)
        let store = try NotesFileStore(path: folder.path)

        do {
            try await store.save(text: "would replace it", index: 0)
            throw VerificationFailure("a write over an unreadable note should have been refused")
        } catch NotesFileStoreError.slotUnreadable {
            // Expected.
        }
        try vexpectEqual(try Data(contentsOf: slot), unreadable, "the unreadable note is still on disk")

        try await store.save(text: "a fresh note", index: 1)
        try vexpectEqual(try VerificationWorkspace.read(VerificationWorkspace.slotURL(folder, 1)), "a fresh note", "other notes still write")
    }

    static func testSlowSnapshotDoesNotUndoALandedWrite() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)
        try "before".write(to: slot, atomically: true, encoding: .utf8)
        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))

        // A read that takes its snapshot at once but answers late, as a busy provider does.
        viewModel.snapshotReader = { store, count in
            let snapshot = store.loadSnapshot(count: count)
            Thread.sleep(forTimeInterval: 0.9)
            return snapshot
        }
        viewModel.updateText("after")
        await viewModel.refreshFromDisk()   // the debounced write lands while this read is out
        await viewModel.flushPendingSaves()

        try vexpectEqual(try VerificationWorkspace.read(slot), "after", "the write landed")
        try vexpectEqual(viewModel.slots[0].text, "after", "the late snapshot did not put the old text back")
    }

    static func testQuittingDoesNotWaitOnAStalledWrite() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let mirrors = RecoveryStore(baseDirectory: recoveryBase).scoped(to: folder.path)
        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))

        // The provider parks a write: the folder's queue is held for longer than the app may wait.
        let parked = FileWriteQueue.shared(for: folder)
        Task.detached { try? await parked.perform { Thread.sleep(forTimeInterval: 2) } }
        try await Task.sleep(nanoseconds: 100_000_000)

        viewModel.updateText("typed just before quitting")
        let began = Date()
        viewModel.flushPendingSaveSynchronously(timeout: 0.3)
        let elapsed = Date().timeIntervalSince(began)
        viewModel.settleRecoveryForTermination()

        try vexpect(elapsed < 1, "quitting waited \(elapsed)s on a folder that did not answer")
        try vexpectEqual(mirrors.contents(ofSlotAt: 0), "typed just before quitting", "the text is kept for the next launch")
    }

    static func testTypingDuringTheFirstReadIsNotWritten() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)
        try "the note on disk".write(to: slot, atomically: true, encoding: .utf8)

        // A synced folder that takes longer to read than the editor's debounce.
        let viewModel = NotesViewModel(recoveryBase: recoveryBase, readTimeout: 3_000_000_000)
        viewModel.snapshotReader = { store, count in
            Thread.sleep(forTimeInterval: 0.9)
            return store.loadSnapshot(count: count)
        }
        let store = try NotesFileStore(path: folder.path)
        let opening = Task { await viewModel.attachFileStore(store) }
        try await Task.sleep(nanoseconds: 100_000_000)
        viewModel.updateText("typed before the note had loaded")
        try await Task.sleep(nanoseconds: 600_000_000)   // the debounce runs out while the read is out

        try vexpectEqual(try VerificationWorkspace.read(slot), "the note on disk", "nothing was written while the folder was being read")

        await opening.value
        await viewModel.flushPendingSaves()
        try vexpectEqual(try VerificationWorkspace.read(slot), "the note on disk", "the unread note was not replaced")
        try vexpectEqual(viewModel.slots[0].text, "the note on disk", "the note shows what the folder holds")
        try vexpectEqual(
            viewModel.recoveryOffers,
            [RecoveryOffer(index: 0, text: "typed before the note had loaded")],
            "what was typed is offered back"
        )
    }

    static func testRepickingTheFolderKeepsNewerDiskContent() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let slot = VerificationWorkspace.slotURL(folder, 0)
        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        viewModel.updateText("written here")
        await viewModel.flushPendingSaves()

        // Another Mac updates the note, and the user re-picks the folder before any refresh ran.
        try "updated on another Mac".write(to: slot, atomically: true, encoding: .utf8)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))
        await viewModel.flushPendingSaves()

        try vexpectEqual(try VerificationWorkspace.read(slot), "updated on another Mac", "the newer note was not overwritten")
        try vexpectEqual(viewModel.slots[0].text, "updated on another Mac", "and it is what the note shows")
    }

    static func testRefreshAppliesSettledSlotsWhileTyping() async throws {
        let folder = try VerificationWorkspace.makeFolder()
        let recoveryBase = try VerificationWorkspace.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: recoveryBase)
        }
        let viewModel = NotesViewModel(recoveryBase: recoveryBase)
        await viewModel.attachFileStore(try NotesFileStore(path: folder.path))

        try "edited on another Mac".write(to: VerificationWorkspace.slotURL(folder, 1), atomically: true, encoding: .utf8)
        viewModel.snapshotReader = { store, count in
            let snapshot = store.loadSnapshot(count: count)
            Thread.sleep(forTimeInterval: 0.5)
            return snapshot
        }
        let refreshing = Task { await viewModel.refreshFromDisk() }
        try await Task.sleep(nanoseconds: 100_000_000)
        viewModel.updateText("typing in the first note")   // lands while the read is out
        await refreshing.value

        try vexpectEqual(viewModel.slots[1].text, "edited on another Mac", "the other note's external edit is shown")
        try vexpectEqual(viewModel.slots[0].text, "typing in the first note", "the typing is untouched")
    }

    static func testChecklistToggleKeepsTheLine() async throws {
        try vexpectEqual(Checklist.toggled("- [ ] buy milk\n"), "- [x] buy milk\n", "an open item is checked")
        try vexpectEqual(Checklist.toggled("- [x] buy milk"), "- [ ] buy milk", "a checked item is opened")
        try vexpectEqual(Checklist.toggled("- [X] buy milk"), "- [ ] buy milk", "an upper-case mark counts as checked")
        try vexpectEqual(Checklist.toggled("    - [ ] nested\n"), "    - [x] nested\n", "indentation is kept")
        try vexpectEqual(Checklist.toggled("  - plain bullet\n"), "  - [ ] plain bullet\n", "a bullet becomes an item in place")
        try vexpectEqual(Checklist.toggled("* star bullet"), "- [ ] star bullet", "other bullet marks become items too")
        try vexpectEqual(Checklist.toggled("just text"), "- [ ] just text", "plain text becomes an item")
        try vexpectEqual(
            Checklist.toggled("- [ ] mentions - [ ] inside"),
            "- [x] mentions - [ ] inside",
            "only the leading marker changes, not text that looks like one"
        )
    }

    static func testChecklistBoxIsTheOnlyTarget() async throws {
        try vexpectEqual(Checklist.boxRange(in: "- [ ] item"), NSRange(location: 2, length: 3), "the box of an item")
        try vexpectEqual(Checklist.boxRange(in: "\t- [x] item"), NSRange(location: 3, length: 3), "the box of an indented item")
        try vexpect(Checklist.boxRange(in: "- plain bullet") == nil, "a bullet has no box")
        try vexpect(Checklist.boxRange(in: "text - [ ] later") == nil, "a marker mid-line is not a box")
        try vexpect(!NSLocationInRange(5, Checklist.boxRange(in: "- [ ] item")!), "the space before the text is a caret spot")
    }

    static func testRecoveryDirectoryFollowsTheRename() async throws {
        let root = try VerificationWorkspace.makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("TotClone/recovery", isDirectory: true)
        let current = root.appendingPathComponent("NoteObs/recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "owed text".write(to: legacy.appendingPathComponent("slot1.md"), atomically: true, encoding: .utf8)

        try vexpectEqual(RecoveryStore.adoptLegacyDirectory(legacy: legacy, current: current), 1, "the old directory is carried over")
        try vexpectEqual(
            try VerificationWorkspace.read(current.appendingPathComponent("slot1.md")),
            "owed text",
            "the unwritten text arrives intact"
        )
        try vexpect(!FileManager.default.fileExists(atPath: legacy.path), "nothing is left behind to be offered twice")

        // The new tree already exists — a NoteObs build ran once — and the old one still owes text.
        let legacyScope = legacy.appendingPathComponent("notes-abc", isDirectory: true)
        let currentScope = current.appendingPathComponent("notes-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyScope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentScope, withIntermediateDirectories: true)
        try "stale".write(to: legacy.appendingPathComponent("slot1.md"), atomically: true, encoding: .utf8)
        try "owed in the old tree".write(to: legacyScope.appendingPathComponent("slot2.md"), atomically: true, encoding: .utf8)
        try "newer in the new tree".write(to: currentScope.appendingPathComponent("slot1.md"), atomically: true, encoding: .utf8)

        try vexpectEqual(
            RecoveryStore.adoptLegacyDirectory(legacy: legacy, current: current),
            1,
            "a mirror the new tree lacks is moved even though the tree exists"
        )
        try vexpectEqual(
            try VerificationWorkspace.read(currentScope.appendingPathComponent("slot2.md")),
            "owed in the old tree",
            "the owed text lands in the same folder scope"
        )
        try vexpectEqual(
            try VerificationWorkspace.read(currentScope.appendingPathComponent("slot1.md")),
            "newer in the new tree",
            "a mirror already in the new tree is untouched"
        )
        try vexpectEqual(
            try VerificationWorkspace.read(current.appendingPathComponent("slot1.md")),
            "owed text",
            "the newer mirror is untouched"
        )
        try vexpectEqual(
            try VerificationWorkspace.read(legacy.appendingPathComponent("slot1.md")),
            "stale",
            "a mirror that could not move is kept, not deleted"
        )
        try vexpect(!FileManager.default.fileExists(atPath: legacyScope.path), "an emptied scope is cleaned up")
    }
}

// MARK: - Command line runner

enum NotesVerification {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--verify")
    }

    final class Tally: @unchecked Sendable {
        var passed = 0
        var failures: [(name: String, detail: String)] = []
    }

    /// Runs every scenario against real folders on disk and exits; used by `make verify`.
    static func runAndExit() -> Never {
        let tally = Tally()
        for testCase in NotesVerificationSuite.cases {
            runOnMainActor {
                do {
                    try await testCase.run()
                    tally.passed += 1
                    print("  ok    \(testCase.name)")
                } catch {
                    tally.failures.append((testCase.name, error.localizedDescription))
                    print("  FAIL  \(testCase.name)\n        \(error)")
                }
            }
        }

        VerificationWorkspace.pruneOldVerifyScopes()

        if tally.failures.isEmpty {
            print("all \(tally.passed) checks passed")
            exit(0)
        }
        print("\(tally.failures.count) of \(tally.passed + tally.failures.count) checks failed")
        exit(1)
    }

    /// Awaiting MainActor work needs the main queue drained, and starting the app is not an option
    /// here: pumping the run loop lets the scenario tasks run without a NSApplication.
    private static func runOnMainActor(_ body: @escaping @MainActor () async -> Void) {
        let finished = RunFlag()
        Task { @MainActor in
            await body()
            finished.set()
        }
        while !finished.isSet {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}

final class RunFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
