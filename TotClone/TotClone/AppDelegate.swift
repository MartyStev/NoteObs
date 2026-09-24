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
            viewModel.attachFileStore(store)
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
            // Suspended, not detached: whatever is typed stays in memory until the folder returns.
            self.viewModel.suspendFileStore()
            self.settings.setFolderState(self.settings.notesFolderPath.isEmpty ? .unconfigured : .inaccessible)
            self.isShowingFolderAlert = true

            let alert = NSAlert()
            alert.messageText = "Папка с заметками недоступна"
            alert.informativeText = "Набранный текст сохранён в памяти. Выберите папку заново, чтобы записать его."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Выбрать папку")
            alert.addButton(withTitle: "Отмена")
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
    private var isResizingFromWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: 22)
        
        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            let image = NSImage(systemSymbolName: "circle", accessibilityDescription: "TotClone")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleStatusItemClick(_:))
            button.target = self
        }

        let contentView = ContentView(
            viewModel: container.viewModel,
            settings: container.settings,
            windowState: container.windowState
        )
        popover.contentSize = NSSize(width: container.settings.windowWidth, height: container.settings.windowHeight)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        Publishers.CombineLatest(container.settings.$windowWidth, container.settings.$windowHeight)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] width, height in
                guard let self else { return }
                self.popover.contentSize = NSSize(width: width, height: height)
                if !self.isResizingFromWindow, let window = self.window, self.container.windowState.isDetached {
                    var frame = window.frame
                    if abs(frame.width - CGFloat(width)) > 1 || abs(frame.height - CGFloat(height)) > 1 {
                        let deltaHeight = CGFloat(height) - frame.height
                        frame.origin.y -= deltaHeight
                        frame.size = CGSize(width: width, height: height)
                        window.setFrame(frame, display: true, animate: false)
                    }
                }
            }
            .store(in: &cancellables)

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

        container.settings.applyLaunchAtLoginPreferenceOnLaunch()
    }
    
    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        
        let headerItem = NSMenuItem(title: "Заметки TotClone", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        for slot in container.viewModel.slots {
            let slotNumber = slot.id + 1
            let trimmed = slot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.isEmpty ? "Пусто" : String(trimmed.prefix(20)).replacingOccurrences(of: "\n", with: " ")
            let title = "\(slotNumber). \(preview)"
            
            let item = NSMenuItem(title: title, action: #selector(selectSlotFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = slot.id
            if container.viewModel.selectedIndex == slot.id {
                item.state = .on
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let openFolderItem = NSMenuItem(title: "Открыть папку в Finder", action: #selector(openFolderFromMenu), keyEquivalent: "")
        openFolderItem.target = self
        openFolderItem.isEnabled = container.settings.isFolderReady
        menu.addItem(openFolderItem)

        let settingsItem = NSMenuItem(title: "Настройки...", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Завершить TotClone", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func selectSlotFromMenu(_ sender: NSMenuItem) {
        container.viewModel.select(index: sender.tag)
        if !popover.isShown && !container.windowState.isDetached {
            togglePopover(nil)
        }
    }

    @objc private func openFolderFromMenu() {
        container.settings.openFolderInFinder()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if container.windowState.isDetached {
            container.viewModel.refreshFromDisk()
            showWindow()
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            container.viewModel.refreshFromDisk()
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
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
            let width = container.settings.windowWidth
            let height = container.settings.windowHeight
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.isMovableByWindowBackground = true
            newWindow.isReleasedWhenClosed = false
            newWindow.isOpaque = false
            newWindow.backgroundColor = .clear
            newWindow.hasShadow = true
            newWindow.hidesOnDeactivate = false
            newWindow.showsResizeIndicator = true
            newWindow.minSize = NSSize(width: 440, height: 280)

            // Hide standard traffic lights for a clean, seamless floating panel design
            newWindow.standardWindowButton(.closeButton)?.isHidden = true
            newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
            newWindow.standardWindowButton(.zoomButton)?.isHidden = true

            newWindow.contentViewController = hosting
            newWindow.center()
            newWindow.delegate = self
            window = newWindow
            windowController = NSWindowController(window: newWindow)
        }
        container.viewModel.refreshFromDisk()
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
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
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

    func windowDidResize(_ notification: Notification) {
        guard let window, notification.object as? NSWindow == window else { return }
        isResizingFromWindow = true
        container.settings.windowWidth = Double(window.frame.width)
        container.settings.windowHeight = Double(window.frame.height)
        isResizingFromWindow = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.viewModel.flushPendingSaveSynchronously()
    }

    func windowWillClose(_ notification: Notification) {
        if container.windowState.isDetached {
            container.windowState.isDetached = false
        }
    }
}
