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
        let texts = try store.loadAll(count: slots.count)
        for index in slots.indices {
            slots[index].text = texts[index]
        }
    }

    func detachFileStore() {
        fileStoreToken = UUID()
        fileStore = nil
    }

    func flushPendingSaves() {
        fileStore?.flushSaves()
    }
}
