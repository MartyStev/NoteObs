# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions match `CFBundleShortVersionString`.

## [0.6] — 2026-10-16

### Added
- App icon: the Big Dipper, seven stars for the seven notes, each in its note's color (`make icon`).
- An "unreadable notes" state: a dialog and a screen with "Check again" and "Open in Finder" buttons.
- A folder that answers late (for example after macOS grants access) is reopened automatically.
- The "not saving" hint now also appears for a write that the cloud folder holds for more than 5 seconds.
- A hint about cloud drives in the folder picker, VoiceOver labels, and a `README.md`.
- `make release-app` builds `dist/NoteObs.app`, a dmg and a zip, signed ad hoc.

### Changed
- New bundle identifier `dev.martystev.noteobs`. Settings and unsent recovery backups from earlier builds are carried over automatically.
- Notes are walked with `⌘⌥←/→`; `⌘←/→` move the caret within the line again. `⌘1…7` and the arrows only act in the notes window.
- A checkbox toggles when you click the `[ ]` itself; links open on a single click; `⌘⇧C` works on non-Latin keyboard layouts.
- Writes go through a separate queue per folder, and each note has its own retry queue.
- Consistent wording across the interface.

### Fixed
- Notes from one folder no longer end up in another when the read of the newly chosen folder stalls.
- A file that exists but can't be read is no longer turned into an empty note or overwritten.
- Text typed before the folder was loaded no longer overwrites notes that haven't been read yet: it is offered back for restoring.
- Picking the same folder again no longer overwrites a note that was updated on another Mac.
- Typing in one note no longer hides an outside edit to another.
- A note emptied while the folder was away stays empty when the folder reconnects.
- The folder is no longer opened twice at launch; picking the same folder again reopens it.
- Quitting no longer waits more than 2 seconds on a stalled write.
- The undo stack is cleared when the note changes; font and colors are no longer reapplied on every keystroke.

## [0.5]

First version with the current feature set: seven notes in the menu bar, storage in `slotN.md`, and backups of unsaved text.
