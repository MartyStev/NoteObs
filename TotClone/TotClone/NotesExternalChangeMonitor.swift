import Dispatch
import Foundation
import Darwin

final class NotesExternalChangeMonitor: @unchecked Sendable {
    private let directoryURL: URL
    private let fileURLs: [URL]
    private let queue = DispatchQueue(label: "TotClone.NotesExternalChangeMonitor", qos: .utility)
    private let onChange: () -> Void
    private let debounceDelay: DispatchTimeInterval = .milliseconds(150)

    private var directorySource: DispatchSourceFileSystemObject?

    private var fileSources: [DispatchSourceFileSystemObject] = []

    private var started = false
    private var debounceItem: DispatchWorkItem?
    private var rebuildScheduled = false

    init(directoryURL: URL, fileURLs: [URL], onChange: @escaping () -> Void) {
        self.directoryURL = directoryURL
        self.fileURLs = fileURLs
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installSources()
        }
    }

    func stop() {
        queue.sync {
            guard started else { return }
            started = false
            debounceItem?.cancel()
            debounceItem = nil

            for source in fileSources {
                source.setEventHandler(handler: nil)
                source.cancel()
            }
            fileSources.removeAll()

            if let directorySource {
                directorySource.setEventHandler(handler: nil)
                directorySource.cancel()
                self.directorySource = nil
            }
        }
    }

    private func installSources() {
        installDirectorySource()
        installFileSources()
    }

    private func installDirectorySource() {
        guard directorySource == nil else { return }
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.signalChange()
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.scheduleRebuild()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        directorySource = source
        source.resume()
    }

    private func installFileSources() {
        for url in fileURLs {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.signalChange()
                let flags = source.data
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.scheduleRebuild()
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            fileSources.append(source)
            source.resume()
        }
    }

    private func signalChange() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [onChange] in
            onChange()
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + debounceDelay, execute: item)
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            guard self.started else { return }
            self.rebuildFileSources()
        }
    }

    private func rebuildFileSources() {
        for source in fileSources {
            source.setEventHandler(handler: nil)
            source.cancel()
        }
        fileSources.removeAll()

        installFileSources()
    }
}
