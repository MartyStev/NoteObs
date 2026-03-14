import AppKit

struct NoteSlot: Identifiable, Equatable {
    let id: Int
    let color: NSColor
    var text: String
}

enum NotesFileStoreError: Error, Equatable {
    case folderMissing
    case notDirectory
    case notReadable
    case notWritable
    case readFailed
    case writeFailed
}
