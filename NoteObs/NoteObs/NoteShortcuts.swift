import AppKit
import SwiftUI

enum CapturedKey: Equatable {
    case left
    case right
    case slot(Int)

    /// The app's note shortcuts: Cmd+Left/Right walks the slots, Cmd+1…7 jumps to one.
    init?(event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
        switch event.keyCode {
        case 123: self = .left
        case 124: self = .right
        default:
            guard let digit = Int(event.characters ?? ""), (1...7).contains(digit) else { return nil }
            self = .slot(digit - 1)
        }
    }
}

/// One keyboard handler for the whole app. The popover and the detached window each used to install
/// their own event monitor, so every shortcut moved the selection twice.
@MainActor
final class NoteShortcutMonitor {
    private var monitor: Any?

    func start(viewModel: NotesViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let key = CapturedKey(event: event) else { return event }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                switch key {
                case .left:
                    viewModel.moveSelection(delta: -1)
                case .right:
                    viewModel.moveSelection(delta: 1)
                case .slot(let index):
                    viewModel.select(index: index)
                }
            }
            return nil
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
