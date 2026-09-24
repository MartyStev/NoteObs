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

    var fileErrorHandler: (() -> Void)?
    private var fileStore: NotesFileStore?
    private var fileStoreToken = UUID()
    private var externalChangeMonitor: NotesExternalChangeMonitor?

    /// Text known to be on disk, per slot. Lets us tell our own write echoing back through the
    /// file monitor from a genuine external edit, even when the disk lags behind the editor.
    private var syncedTexts: [String]

    private var saveTask: Task<Void, Never>?
    private var pendingSave: (index: Int, text: String)?
    private var saveGeneration = 0
    private var saveAttempt = 0
    private var attachedPath: String?
    private let saveDebounce: UInt64 = 400_000_000
    private let retryDelays: [UInt64] = [1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000, 15_000_000_000]

    init() {
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
    func attachFileStore(_ store: NotesFileStore) {
        let resuming = attachedPath == store.folderURL.path
        fileStoreToken = UUID()
        fileStore = store
        attachedPath = store.folderURL.path
        pendingSave = nil
        saveAttempt = 0
        isSaveFailing = false

        let diskTexts = store.loadSnapshot(count: slots.count)
        store.ensureSlotFiles(count: slots.count)

        for index in slots.indices {
            let localText = slots[index].text
            let diskText = diskTexts[index]

            if resuming, !localText.isEmpty, localText != diskText {
                do {
                    try store.saveSynchronously(text: localText, index: index)
                    syncedTexts[index] = localText
                } catch {
                    syncedTexts[index] = diskText ?? ""
                    scheduleSave(text: localText, index: index, delay: retryDelays[0])
                }
                continue
            }

            slots[index].text = diskText ?? ""
            syncedTexts[index] = diskText ?? ""
        }

        externalChangeMonitor?.stop()
        let expectedToken = fileStoreToken
        externalChangeMonitor = NotesExternalChangeMonitor(
            directoryURL: store.directoryURL,
            fileURLs: store.fileURLs(count: slots.count)
        ) { [weak self] in
            Task { @MainActor in
                guard let self, self.fileStoreToken == expectedToken else { return }
                self.refreshFromDisk()
            }
        }
        externalChangeMonitor?.start()
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
    func detachFileStore() {
        suspendFileStore()
        pendingSave = nil
        attachedPath = nil
        syncedTexts = Array(repeating: "", count: slots.count)
        isSaveFailing = false
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
        } catch {
            // Terminating: there is no time to present the folder alert or retry.
        }
    }

    func refreshFromDisk() {
        guard let fileStore else { return }
        let expectedToken = fileStoreToken
        let texts = fileStore.loadSnapshot(count: slots.count)
        guard fileStoreToken == expectedToken else { return }

        for index in slots.indices {
            guard let diskText = texts[index] else { continue }
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
