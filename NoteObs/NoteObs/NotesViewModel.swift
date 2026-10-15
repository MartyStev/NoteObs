import AppKit
import Combine

@MainActor
final class WindowState: ObservableObject {
    @Published var isDetached: Bool = false
    @Published var isPinned: Bool = false
}

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var selectedIndex: Int = 0
    @Published var slots: [NoteSlot]

    /// Text that is typed but not on disk yet. Shown as a non-blocking hint instead of an alert.
    @Published private(set) var isSaveFailing = false

    /// Unwritten text a previous session left behind, waiting for the user to accept or drop it.
    @Published private(set) var recoveryOffers: [RecoveryOffer] = []

    var fileErrorHandler: (() -> Void)?
    /// Called when the folder stopped answering reads altogether, which is how a permission stall
    /// looks from the inside: the request simply never comes back.
    var folderStalledHandler: (() -> Void)?
    /// Called with the slot indices whose files exist but could not be read; the folder is not opened.
    var folderUnreadableHandler: (([Int]) -> Void)?
    private(set) var isFolderStalled = false
    private var fileStore: NotesFileStore?
    private var fileStoreToken = UUID()
    private var externalChangeMonitor: NotesExternalChangeMonitor?
    private var recovery: RecoveryStore

    /// Text known to be on disk, per slot. Lets us tell our own write echoing back through the
    /// file monitor from a genuine external edit, even when the disk lags behind the editor.
    private var syncedTexts: [String]

    private var saveTask: Task<Void, Never>?
    private var pendingSave: (index: Int, text: String)?
    private var saveGeneration = 0
    private var saveAttempt = 0
    private var attachedPath: String?
    /// How the folder is read. The regression checks swap it to stage a folder that answers late.
    var snapshotReader: @Sendable (NotesFileStore, Int) -> [SlotRead] = { store, count in
        store.loadSnapshot(count: count)
    }
    /// The folder the text in the slots belongs to: set only once that folder has actually been read.
    /// `attachedPath` says where we were pointed; this says whose notes we are holding.
    private var contentFolderKey: String?
    private let saveDebounce: UInt64 = 400_000_000
    private let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 15_000_000_000]

    /// A healthy synced folder answers in well under this. A folder the system is still asking
    /// about never answers at all, so waiting longer than this buys nothing but a frozen app.
    private let readTimeout: UInt64

    /// File I/O belongs on a GCD queue rather than the cooperative pool: a read parked inside an
    /// open() would otherwise take a worker thread with it for good, and the pool has few to spare.
    private static let ioQueue = DispatchQueue(
        label: "NoteObs.NotesIO",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// The mirror tree is named here rather than handed in ready-made, so a caller that only wants
    /// its own throwaway copies — the regression checks do — never reaches the user's real one.
    /// Attaching a folder narrows this to the mirrors that folder owes.
    init(recoveryBase: URL = RecoveryStore.defaultDirectoryURL(), readTimeout: UInt64 = 5_000_000_000) {
        self.readTimeout = readTimeout
        let colors: [NSColor] = [
            NSColor.systemRed,
            NSColor.systemOrange,
            NSColor.systemYellow,
            NSColor.systemGreen,
            NSColor.systemTeal,
            NSColor.systemBlue,
            NSColor.systemPurple
        ]
        self.slots = colors.enumerated().map { index, color in
            NoteSlot(id: index, color: color, text: "")
        }
        self.syncedTexts = Array(repeating: "", count: colors.count)
        self.recovery = RecoveryStore(baseDirectory: recoveryBase)
    }

    deinit {
        externalChangeMonitor?.stop()
    }

    func select(index: Int) {
        guard slots.indices.contains(index), index != selectedIndex else { return }
        flushPendingSave()
        selectedIndex = index
    }

    func moveSelection(delta: Int) {
        let count = slots.count
        guard count > 0 else { return }
        let next = (selectedIndex + delta + count) % count
        guard next != selectedIndex else { return }
        flushPendingSave()
        selectedIndex = next
    }

    func updateText(_ text: String) {
        guard slots.indices.contains(selectedIndex) else { return }
        let index = selectedIndex
        slots[index].text = text
        scheduleSave(text: text, index: index, delay: saveDebounce)
    }

    private func scheduleSave(text: String, index: Int, delay: UInt64) {
        // Mirror before anything else: if no folder currently holds this text — suspended after an
        // error, or wedged behind a permission that never arrived — the typed note still has to
        // survive the process quitting.
        if fileStore != nil || attachedPath != nil {
            recovery.mirror(text: text, index: index)
        }
        guard let fileStore else { return }
        saveTask?.cancel()
        pendingSave = (index, text)
        saveGeneration += 1
        let generation = saveGeneration
        let expectedToken = fileStoreToken

        saveTask = Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay)
                }
                try Task.checkCancellation()
                try await fileStore.save(text: text, index: index)
                guard !Task.isCancelled else { return }
                guard let self, self.fileStoreToken == expectedToken, self.saveGeneration == generation else { return }
                self.syncedTexts[index] = text
                self.pendingSave = nil
                self.saveAttempt = 0
                self.isSaveFailing = false
                self.recovery.discard(index: index)
            } catch let error {
                let storeError = (error as? NotesFileStoreError) ?? .writeFailed
                self?.handleSaveFailure(storeError, text: text, index: index, generation: generation, token: expectedToken)
            }
        }
    }

    /// Keeps the typed text queued and retries it, so a busy or briefly unavailable synced
    /// folder cannot discard what the user has just written.
    private func handleSaveFailure(
        _ error: NotesFileStoreError,
        text: String,
        index: Int,
        generation: Int,
        token: UUID
    ) {
        guard !Task.isCancelled, fileStoreToken == token, saveGeneration == generation else { return }
        guard pendingSave?.index == index, pendingSave?.text == text else { return }

        if error.isFatal {
            fileErrorHandler?()
            return
        }

        isSaveFailing = true
        let delay = retryDelays[min(saveAttempt, retryDelays.count - 1)]
        saveAttempt += 1
        scheduleSave(text: text, index: index, delay: delay)
    }

    /// Writes the queued slot immediately, e.g. before switching slots.
    private func flushPendingSave() {
        guard let pending = pendingSave else { return }
        saveTask?.cancel()
        pendingSave = nil
        scheduleSave(text: pending.text, index: pending.index, delay: 0)
    }

    /// Attaches a notes folder. When this is the folder a previous session was suspended on,
    /// the text kept in memory wins: the folder went away while it owed us a write.
    ///
    /// Text a dead session left unwritten is surfaced as a recovery offer instead of being applied
    /// or discarded silently.
    func attachFileStore(_ store: NotesFileStore) async {
        let folderKey = NotesFolderIdentity.key(for: store.folderURL.path)
        // "Resuming" means the text in the slots was read from, or written to, this very folder, and
        // the folder was only suspended, not detached. Being pointed at it once is not enough: a read
        // that never answered leaves the previous folder's notes in the slots, and treating those as
        // owed to this folder would write them into it. A detach forgets the claim, so the folder's
        // own content wins when it comes back.
        let resuming = contentFolderKey == folderKey && attachedPath == folderKey
        if let contentFolderKey, contentFolderKey != folderKey {
            // The slots hold another folder's notes. Showing them against this folder, or letting
            // typing mirror them into its recovery scope, would carry them across on the next read.
            for index in slots.indices { slots[index].text = "" }
            syncedTexts = Array(repeating: "", count: slots.count)
            self.contentFolderKey = nil
        }
        let token = UUID()
        fileStoreToken = token
        fileStore = store
        attachedPath = folderKey
        pendingSave = nil
        saveAttempt = 0
        isSaveFailing = false
        isFolderStalled = false
        // Scoped by the path the folder was opened under, so the other spelling of the same folder
        // stays readable as a legacy mirror location.
        recovery = recovery.scoped(to: store.folderURL.path)
        var offers: [RecoveryOffer] = []
        recoveryOffers = offers

        let snapshot = await readSnapshot(of: store)
        guard fileStoreToken == token else { return }
        guard case .loaded(let diskTexts) = snapshot else {
            // The folder is not answering. Say so and keep the text we hold instead of starting up
            // as an empty, unreachable note.
            isFolderStalled = true
            suspendFileStore()
            folderStalledHandler?()
            return
        }
        let unreadable = diskTexts.indices.filter { diskTexts[$0] == .unreadable }
        guard unreadable.isEmpty else {
            // A file that exists but will not read is not an empty note. Opening the folder anyway
            // would blank the slot and let the first keystroke replace the real content, so the
            // folder stays closed and typing goes to the mirror only.
            suspendFileStore()
            folderUnreadableHandler?(unreadable)
            return
        }
        contentFolderKey = folderKey
        let slotCount = slots.count
        await Self.offMain { store.ensureSlotFiles(count: slotCount) }
        guard fileStoreToken == token else { return }

        for index in slots.indices {
            let localText = slots[index].text
            let diskText = diskTexts[index].text
            let mirrored = recovery.contents(ofSlotAt: index)

            // The folder already holds the mirrored text; the session simply died before cleanup.
            if let mirrored, mirrored == diskText {
                recovery.discard(index: index)
            }

            // Local text the folder still owes is newer than the snapshot just read: the same folder
            // went away owing a write, or the text was typed before this folder was ever read and the
            // slot on disk is empty. Typing into a slot whose real content had not loaded yet is not
            // an edit of that content, so a non-empty note on disk is offered back, never replaced.
            let diskHasNote = !(diskText ?? "").isEmpty
            let typedBeforeRead = mirrored == localText && !diskHasNote
            if !localText.isEmpty, localText != diskText, resuming || typedBeforeRead {
                do {
                    try store.saveSynchronously(text: localText, index: index)
                    syncedTexts[index] = localText
                    recovery.discard(index: index)
                } catch {
                    syncedTexts[index] = diskText ?? ""
                    scheduleSave(text: localText, index: index, delay: retryDelays[0])
                }
                continue
            }

            slots[index].text = diskText ?? ""
            syncedTexts[index] = diskText ?? ""

            if let mirrored, mirrored != diskText {
                offers.append(RecoveryOffer(index: index, text: mirrored))
            }
        }
        recoveryOffers = offers

        externalChangeMonitor?.stop()
        let expectedToken = fileStoreToken
        externalChangeMonitor = NotesExternalChangeMonitor(
            directoryURL: store.directoryURL,
            fileURLs: store.fileURLs(count: slots.count)
        ) { [weak self] in
            Task { @MainActor in
                guard let self, self.fileStoreToken == expectedToken else { return }
                await self.refreshFromDisk()
            }
        }
        externalChangeMonitor?.start()
    }

    /// Puts unwritten text back into the note and into the folder.
    func acceptRecovery(_ offer: RecoveryOffer) {
        guard slots.indices.contains(offer.index) else { return }
        recoveryOffers.removeAll { $0.index == offer.index }
        slots[offer.index].text = offer.text

        guard let fileStore else {
            // No folder to write into yet: keep the mirror alive so the text is still owed.
            recovery.mirror(text: offer.text, index: offer.index)
            return
        }
        // Another slot may still be mid-debounce; a single save task means it would be dropped.
        if let pending = pendingSave, pending.index != offer.index {
            flushPendingSaveSynchronously()
        }
        do {
            try fileStore.saveSynchronously(text: offer.text, index: offer.index)
            syncedTexts[offer.index] = offer.text
            recovery.discard(index: offer.index)
        } catch {
            scheduleSave(text: offer.text, index: offer.index, delay: retryDelays[0])
        }
    }

    /// Drops unwritten text in favour of what the folder holds.
    func declineRecovery(_ offer: RecoveryOffer) {
        recoveryOffers.removeAll { $0.index == offer.index }
        recovery.discard(index: offer.index)
    }

    /// Stops using the folder after a fatal error, keeping typed text for the next attempt.
    func suspendFileStore() {
        saveTask?.cancel()
        saveTask = nil
        saveGeneration += 1
        fileStoreToken = UUID()
        fileStore = nil
        externalChangeMonitor?.stop()
        externalChangeMonitor = nil
    }

    /// Forgets the folder for good: on an explicit folder change the in-memory state is stale.
    ///
    /// `contentFolderKey` deliberately survives: the slots still show that folder's notes, and the
    /// next attach has to know it, or a different folder would be handed them as its own.
    func detachFileStore() {
        suspendFileStore()
        pendingSave = nil
        attachedPath = nil
        isFolderStalled = false
        syncedTexts = Array(repeating: "", count: slots.count)
        isSaveFailing = false
        recoveryOffers = []
    }

    func flushPendingSaves() async {
        _ = await saveTask?.result
    }

    /// Writes queued text without waiting for the debounce, used when the app is terminating.
    func flushPendingSaveSynchronously() {
        saveTask?.cancel()
        saveTask = nil
        saveGeneration += 1
        defer { pendingSave = nil }
        guard let pending = pendingSave, let fileStore else { return }
        do {
            try fileStore.saveSynchronously(text: pending.text, index: pending.index)
            syncedTexts[pending.index] = pending.text
            recovery.discard(index: pending.index)
        } catch {
            // Terminating: there is no time to present the folder alert or retry. The mirror keeps
            // the text, and the next launch offers it back.
        }
    }

    /// Reads the folder off the main actor: on a synced drive a healthy read of seven files can
    /// still block for hundreds of milliseconds while the provider is catching up.
    func refreshFromDisk() async {
        guard let fileStore, !isFolderStalled else { return }
        let expectedToken = fileStoreToken
        let expectedGeneration = saveGeneration
        let outcome = await readSnapshot(of: fileStore)
        guard fileStoreToken == expectedToken else { return }
        guard case .loaded(let texts) = outcome else {
            isFolderStalled = true
            suspendFileStore()
            folderStalledHandler?()
            return
        }
        let unreadable = texts.indices.filter { texts[$0] == .unreadable }
        guard unreadable.isEmpty else {
            // A note went unreadable under an open folder. The next save to it would replace whatever
            // it now holds, so writing stops before any keystroke can. The text we hold is no longer
            // known to match the folder: on reopening, the folder's content wins and anything still
            // owed is offered back rather than written over it.
            contentFolderKey = nil
            suspendFileStore()
            folderUnreadableHandler?(unreadable)
            return
        }
        // A keystroke landed while we were reading, so what we read is behind by definition.
        guard saveGeneration == expectedGeneration else { return }
        applyDiskSnapshot(texts)
    }

    /// Lands every queued mirror. Called before the synchronous write on termination: that write
    /// can stall forever on an unreachable folder, and the text has to be safe before it does.
    func settleRecoveryForTermination() {
        recovery.settle()
    }

    private enum FolderRead: Sendable {
        case loaded([SlotRead])
        case stalled
    }

    /// Reads the folder, giving up on it once waiting longer says more than the read can.
    ///
    /// A folder macOS is still asking the user about never answers: the open() call sits in the
    /// kernel for as long as the process lives. Abandoning the read is what keeps the app usable;
    /// the parked thread goes away with the process, and the answer it eventually brings back is
    /// dropped by the token guard at the call site.
    private func readSnapshot(of store: NotesFileStore) async -> FolderRead {
        let count = slots.count
        let reader = snapshotReader
        guard let texts = await Self.readWithinDeadline(deadlineNanoseconds: readTimeout, {
            reader(store, count)
        }) else {
            return .stalled
        }
        return .loaded(texts)
    }

    /// Runs a blocking folder read where blocking belongs — a GCD queue, not the cooperative pool,
    /// which cannot spare a worker thread for good — and answers nil if it has not finished by the
    /// deadline. The read itself keeps running and its result is simply never looked at again.
    static func readWithinDeadline<T: Sendable>(
        deadlineNanoseconds: UInt64,
        pollingIntervalNanoseconds: UInt64 = 25_000_000,
        _ read: @escaping @Sendable () -> T
    ) async -> T? {
        let result = ReadResult<T>()
        ioQueue.async {
            result.set(read())
        }
        var waited: UInt64 = 0
        while waited < deadlineNanoseconds {
            if let value = result.value { return value }
            try? await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
            waited += pollingIntervalNanoseconds
        }
        return result.value
    }

    private static func offMain(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                work()
                continuation.resume()
            }
        }
    }

    private func applyDiskSnapshot(_ reads: [SlotRead]) {
        for index in slots.indices {
            // Missing and unreadable files are left alone: neither is evidence the note changed.
            guard let diskText = reads[index].text else { continue }
            // Our own write coming back through the file monitor.
            if diskText == syncedTexts[index] { continue }
            // Unsaved local typing is authoritative; the disk copy is behind, not ahead.
            if slots[index].text != syncedTexts[index] { continue }
            // Never blank a note over a transient or half-synced read.
            if diskText.isEmpty, !syncedTexts[index].isEmpty { continue }

            syncedTexts[index] = diskText
            slots[index].text = diskText
        }
    }
}

/// A value handed over by whichever worker gets there first, read by whoever is still waiting.
/// The lock is the whole protocol: a blocked reader never writes, a finished one writes once.
final class ReadResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func set(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = value }
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
