import AppKit
import SwiftUI

enum CapturedKey: Equatable {
    case left
    case right
    case slot(Int)

    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124

    /// The modifiers a person holds. Arrow and function keys also carry `.numericPad` and `.function`,
    /// which are not choices anyone makes and must not make a shortcut miss.
    private static let chordMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// The app's note shortcuts: Cmd+Option+Left/Right walks the notes, as it walks tabs in Safari,
    /// and Cmd+1…7 jumps to one. Cmd+Left/Right alone stays with the editor, which moves to the start
    /// or end of the line with it.
    init?(event: NSEvent) {
        let chord = event.modifierFlags.intersection(Self.chordMask)
        switch event.keyCode {
        case Self.leftArrow where chord == [.command, .option]:
            self = .left
        case Self.rightArrow where chord == [.command, .option]:
            self = .right
        default:
            guard chord == .command,
                  let digit = Int(event.charactersIgnoringModifiers ?? ""),
                  (1...7).contains(digit) else { return nil }
            self = .slot(digit - 1)
        }
    }
}

/// One keyboard handler for the whole app. The popover and the detached window each used to install
/// their own event monitor, so every shortcut moved the selection twice.
@MainActor
final class NoteShortcutMonitor {
    private var monitor: Any?

    /// Which windows the shortcuts belong to. Set by the app delegate once the notes popover and
    /// window exist; until then, and in every other window — settings, alerts — keys pass through.
    var isNotesWindow: (NSWindow?) -> Bool = { _ in false }

    func start(viewModel: NotesViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  NSApp.modalWindow == nil,
                  self.isNotesWindow(event.window),
                  !Self.isComposingText(in: event.window),
                  let key = CapturedKey(event: event) else { return event }
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

    /// An input method mid-composition owns the keyboard; switching notes under it loses the text.
    private static func isComposingText(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
}
