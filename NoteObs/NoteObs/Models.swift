import AppKit

struct NoteSlot: Identifiable, Equatable {
    let id: Int
    let color: NSColor
    var text: String
}

/// Text a previous session never managed to write into the notes folder, waiting on the user's
/// decision: put it back, or leave the folder's copy alone.
struct RecoveryOffer: Identifiable, Equatable {
    let index: Int
    let text: String
    var id: Int { index }
}

enum NotesFileStoreError: Error, Equatable {
    case folderMissing
    case notDirectory
    case notReadable
    case notWritable
    case writeFailed
}

extension NotesFileStoreError {
    /// A fatal error means the folder itself is unusable and the user has to intervene.
    /// Anything else is a momentary hiccup of a synced folder and is worth retrying.
    var isFatal: Bool {
        switch self {
        case .folderMissing, .notDirectory, .notReadable, .notWritable:
            return true
        case .writeFailed:
            return false
        }
    }
}
