import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

@MainActor
final class AppContainer {
    static let shared = AppContainer()
    let viewModel = NotesViewModel()
    let settings = AppSettings()
    let windowState = WindowState()

    private var folderCancellable: AnyCancellable?
    private var isShowingFolderAlert = false

    private init() {
        viewModel.fileErrorHandler = { [weak self] in
            self?.handleInvalidFolder()
        }

        folderCancellable = settings.$notesFolderPath
            .sink { [weak self] path in
                self?.configureFileStore(path: path)
            }
    }

    private func configureFileStore(path: String) {
        guard !path.isEmpty else {
            viewModel.detachFileStore()
            settings.setFolderState(.unconfigured)
            return
        }
        do {
            let store = try NotesFileStore(path: path)
            try viewModel.attachFileStore(store)
            settings.setFolderState(.available)
        } catch {
            viewModel.detachFileStore()
            settings.setFolderState(.inaccessible)
            handleInvalidFolder()
        }
    }

    private func handleInvalidFolder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShowingFolderAlert else { return }
            self.viewModel.detachFileStore()
            self.settings.setFolderState(self.settings.notesFolderPath.isEmpty ? .unconfigured : .inaccessible)
            self.isShowingFolderAlert = true

            let alert = NSAlert()
            alert.messageText = "Folder Access Error"
            alert.informativeText = "Cannot access the notes folder. Please select it again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Select Folder")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            self.isShowingFolderAlert = false
            if response == .alertFirstButtonReturn {
                self.settings.promptForFolder()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let container = AppContainer.shared
    private var window: NSWindow?
    private var windowController: NSWindowController?
    private var settingsWindow: NSWindow?
    private var settingsWindowController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular, scale: .medium)
            let image = NSImage(
                systemSymbolName: "circle",
                accessibilityDescription: "Notes"
            )?.withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let contentView = ContentView(
            viewModel: container.viewModel,
            settings: container.settings,
            windowState: container.windowState
        )
        popover.contentSize = NSSize(width: 720, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        container.windowState.$isDetached
            .removeDuplicates()
            .sink { [weak self] detached in
                self?.applyDetach(detached)
            }
            .store(in: &cancellables)

        container.windowState.$isPinned
            .removeDuplicates()
            .sink { [weak self] pinned in
                self?.applyPin(pinned)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettingsWindow),
            name: .openSettingsWindow,
            object: nil
        )

        if !container.settings.hasFolderSelection {
            DispatchQueue.main.async { [weak self] in
                self?.container.settings.promptForFolder()
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if container.windowState.isDetached {
            showWindow()
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func applyDetach(_ detached: Bool) {
        if detached {
            if popover.isShown {
                popover.performClose(nil)
            }
            showWindow()
        } else {
            closeWindow()
        }
    }

    private func applyPin(_ pinned: Bool) {
        guard let window else { return }
        window.level = pinned ? .statusBar : .normal
        window.hidesOnDeactivate = false
        if pinned {
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.orderFrontRegardless()
        } else {
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        }
    }

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: ContentView(
                    viewModel: container.viewModel,
                    settings: container.settings,
                    windowState: container.windowState
                )
            )
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.isMovableByWindowBackground = true
            newWindow.isReleasedWhenClosed = false
            newWindow.hidesOnDeactivate = false
            newWindow.minSize = NSSize(width: 520, height: 320)
            newWindow.contentViewController = hosting
            newWindow.center()
            newWindow.delegate = self
            window = newWindow
            windowController = NSWindowController(window: newWindow)
        }
        applyPin(container.windowState.isPinned)
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        window?.orderOut(nil)
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(settings: container.settings)
            )
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "Настройки"
            newWindow.isReleasedWhenClosed = false
            newWindow.contentViewController = hosting
            newWindow.center()
            settingsWindow = newWindow
            settingsWindowController = NSWindowController(window: newWindow)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if container.windowState.isDetached {
            container.windowState.isDetached = false
        }
    }
}
