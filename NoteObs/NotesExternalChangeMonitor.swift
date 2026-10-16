import Dispatch
import Foundation
import Darwin

/// Watches the notes folder and its slot files.
///
/// Every file here is opened with `open()`, and on a synced or unapproved folder that call can sit
/// in the kernel indefinitely. Nothing on the main thread may wait behind it, so the state is kept
/// under a lock and sources are cancelled by whoever notices — the queue only ever installs.
final class NotesExternalChangeMonitor: @unchecked Sendable {
    private let directoryURL: URL
    private let fileURLs: [URL]
    private let queue = DispatchQueue(label: "NoteObs.NotesExternalChangeMonitor", qos: .utility)
    private let onChange: @Sendable () -> Void
    private let debounceDelay: DispatchTimeInterval = .milliseconds(150)

    private let lock = NSLock()
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var started = false
    private var debounceItem: DispatchWorkItem?
    private var rebuildScheduled = false

    init(directoryURL: URL, fileURLs: [URL], onChange: @escaping @Sendable () -> Void) {
        self.directoryURL = directoryURL
        self.fileURLs = fileURLs
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    var isStarted: Bool {
        withLock { started }
    }

    func start() {
        let shouldInstall = withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldInstall else { return }

        queue.async { [weak self] in
            guard let self, self.isStarted else { return }
            self.installSources()
        }
    }

    /// Cancels what exists without touching the queue, which an install may be holding for good.
    func stop() {
        let victims = withLock { () -> [DispatchSourceFileSystemObject] in
            started = false
            rebuildScheduled = false
            debounceItem?.cancel()
            debounceItem = nil

            var all = fileSources
            fileSources.removeAll()
            if let directorySource {
                all.append(directorySource)
                self.directorySource = nil
            }
            return all
        }
        Self.cancel(victims)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func cancel(_ sources: [DispatchSourceFileSystemObject]) {
        for source in sources {
            source.setEventHandler(handler: nil)
            source.cancel()
        }
    }

    /// A source that was built but never taken still has to be let go, and libdispatch only allows
    /// cancelling one that has been resumed at least once. The cancel handler closes the descriptor.
    private func discard(_ source: DispatchSourceFileSystemObject) {
        source.resume()
        Self.cancel([source])
    }

    private func installSources() {
        installDirectorySource()
        installFileSources()
    }

    private func installDirectorySource() {
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = makeSource(fd: fd) { [weak self] in self?.signalChange() }
        guard adopt(source, isDirectory: true) else {
            discard(source)
            return
        }
        source.resume()
    }

    private func installFileSources() {
        for url in fileURLs {
            guard isStarted else { return }
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = makeSource(fd: fd) { [weak self] in self?.signalChange() }
            // Stopped while this open() was parked: drop the source instead of resurrecting it.
            guard adopt(source, isDirectory: false) else {
                discard(source)
                return
            }
            source.resume()
        }
    }

    private func makeSource(
        fd: Int32,
        onChange: @escaping @Sendable () -> Void
    ) -> DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            onChange()
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.scheduleRebuild()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        return source
    }

    /// Takes ownership of a freshly built source, and says whether the monitor still wants it.
    @discardableResult
    private func adopt(_ source: DispatchSourceFileSystemObject, isDirectory: Bool) -> Bool {
        withLock {
            guard started else { return false }
            if isDirectory {
                directorySource = source
            } else {
                fileSources.append(source)
            }
            return true
        }
    }

    private func signalChange() {
        guard isStarted else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isStarted else { return }
            self.onChange()
        }
        let previous = withLock { () -> DispatchWorkItem? in
            let old = debounceItem
            debounceItem = item
            return old
        }
        previous?.cancel()
        queue.asyncAfter(deadline: .now() + debounceDelay, execute: item)
    }

    private func scheduleRebuild() {
        let shouldSchedule = withLock { () -> Bool in
            guard started, !rebuildScheduled else { return false }
            rebuildScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self else { return }
            self.withLock { self.rebuildScheduled = false }
            self.rebuildFileSources()
        }
    }

    private func rebuildFileSources() {
        guard isStarted else { return }
        let victims = withLock { () -> [DispatchSourceFileSystemObject] in
            let old = fileSources
            fileSources.removeAll()
            return old
        }
        Self.cancel(victims)
        installFileSources()
    }
}
