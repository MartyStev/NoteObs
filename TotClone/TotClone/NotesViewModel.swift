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
    var fileErrorHandler: (() -> Void)?
    private var fileStore: NotesFileStore?
    private var fileStoreToken = UUID()
    private var externalChangeMonitor: NotesExternalChangeMonitor?

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
    }

    deinit {
        externalChangeMonitor?.stop()
    }

    func select(index: Int) {
        guard slots.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(delta: Int) {
        let count = slots.count
        guard count > 0 else { return }
        let next = (selectedIndex + delta + count) % count
        selectedIndex = next
    }

    func updateText(_ text: String) {
        guard slots.indices.contains(selectedIndex) else { return }
        let index = selectedIndex
        slots[index].text = text
        guard let fileStore else { return }

        let expectedToken = fileStoreToken
        fileStore.save(text: text, index: index) { [weak self] result in
            guard
                let self,
                self.fileStoreToken == expectedToken
            else {
                return
            }

            if case .failure = result {
                self.fileErrorHandler?()
            }
        }
    }

    func attachFileStore(_ store: NotesFileStore) throws {
        fileStoreToken = UUID()
        fileStore = store
        refreshFromDisk()

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

    func detachFileStore() {
        fileStoreToken = UUID()
        fileStore = nil
        externalChangeMonitor?.stop()
        externalChangeMonitor = nil
    }

    func flushPendingSaves() {
        fileStore?.flushSaves()
    }

    func refreshFromDisk() {
        guard let fileStore else { return }
        let expectedToken = fileStoreToken
        do {
            let texts = try fileStore.loadAll(count: slots.count)
            guard fileStoreToken == expectedToken else { return }
            for index in slots.indices where slots[index].text != texts[index] {
                slots[index].text = texts[index]
            }
        } catch {
            fileErrorHandler?()
        }
    }
}
