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
    private var recoveryCancellable: AnyCancellable?
    private let shortcuts = NoteShortcutMonitor()
    private var isShowingFolderAlert = false
    private var isShowingRecoveryAlert = false
    private var isShowingUnreadableAlert = false
    private var hasWarnedAboutStalledFolder = false

    private init() {
        viewModel.fileErrorHandler = { [weak self] in
            self?.handleInvalidFolder()
        }
        viewModel.folderStalledHandler = { [weak self] in
            self?.handleStalledFolder()
        }
        viewModel.folderAnsweredHandler = { [weak self] in
            self?.configureFileStore()
        }
        viewModel.folderUnreadableHandler = { [weak self] slotIndices in
            self?.handleUnreadableSlots(slotIndices)
        }
        settings.folderRetryHandler = { [weak self] in
            self?.configureFileStore()
        }

        shortcuts.start(viewModel: viewModel)

        // A @Published property hands its current value to a new subscriber, so this also opens the
        // folder an earlier run saved. Calling configureFileStore() here as well would open it twice.
        folderCancellable = settings.$notesFolderPath
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.configureFileStore()
            }

        // Text a previous session could not write is the user's call, not ours: ask, never merge
        // it into a note or throw it away silently.
        recoveryCancellable = viewModel.$recoveryOffers
            .sink { [weak self] offers in
                guard !offers.isEmpty else { return }
                self?.presentRecoveryAlert()
            }
    }

    /// Tells the shortcut handler which windows hold the notes; every other window keeps its keys.
    func routeShortcuts(to isNotesWindow: @escaping (NSWindow?) -> Bool) {
        shortcuts.isNotesWindow = isNotesWindow
    }

    private func configureFileStore() {
        guard let url = settings.folderURLForAccess() else {
            viewModel.detachFileStore()
            settings.setFolderState(.unconfigured)
            return
        }
        do {
            // The URL may carry a security scope; the store releases it again when it is dropped.
            let store = try NotesFileStore(url: url, securingAccess: true)
            settings.setFolderState(.available)
            // Reading the folder happens off the main actor, so this cannot block first paint.
            Task { await viewModel.attachFileStore(store) }
        } catch {
            viewModel.detachFileStore()
            settings.setFolderState(.inaccessible)
            handleInvalidFolder()
        }
    }

    /// Offers the text the previous session could not write into the folder.
    ///
    /// The whole pending list is decided at once: the offers land together while the folder is
    /// being read, and answering them one by one would re-raise an alert the user has settled.
    private func presentRecoveryAlert() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShowingRecoveryAlert else { return }
            let offers = self.viewModel.recoveryOffers
            guard !offers.isEmpty else { return }
            self.isShowingRecoveryAlert = true

            let alert = NSAlert()
            alert.messageText = "Есть текст, который не записался в папку"
            alert.informativeText = Self.describe(offers)
                + "\n\nПрошлая сессия завершилась, пока запись в папку заметок не удалась."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Восстановить")
            alert.addButton(withTitle: "Оставить то, что в папке")

            let response = alert.runModal()
            self.isShowingRecoveryAlert = false
            let stillOffered = offers.filter { self.viewModel.recoveryOffers.contains($0) }
            switch response {
            case .alertFirstButtonReturn:
                for offer in stillOffered { self.viewModel.acceptRecovery(offer) }
            default:
                for offer in stillOffered { self.viewModel.declineRecovery(offer) }
            }
        }
    }

    private static func describe(_ offers: [RecoveryOffer]) -> String {
        offers.map { offer in
            let preview = offer.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let shortened = preview.count > 60 ? String(preview.prefix(60)) + "…" : preview
            return "Слот \(offer.index + 1): \(shortened.isEmpty ? "(пусто)" : shortened)"
        }
        .joined(separator: "\n")
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

    /// A note file exists but cannot be read. The folder stays closed so the file is never replaced
    /// by a blank note; whatever is typed meanwhile is kept outside the folder.
    private func handleUnreadableSlots(_ slotIndices: [Int]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The state is set even when the alert is already up: it is what keeps the editor closed.
            self.settings.setFolderState(.unreadableNotes)
            guard !self.isShowingUnreadableAlert else { return }
            self.isShowingUnreadableAlert = true

            let names = slotIndices.map { "\($0 + 1)" }.joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "Не удалось прочитать заметки в папке"
            alert.informativeText = """
            Файлы слотов: \(names). Они есть в папке, но не читаются — это не UTF-8, вместо файла \
            лежит каталог, либо синхронизация ещё не принесла содержимое.

            Запись в папку остановлена, чтобы не затереть эти файлы. Набранный сейчас текст \
            сохраняется отдельно. Исправьте файлы или дождитесь синхронизации и повторите.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Повторить")
            alert.addButton(withTitle: "Открыть в Finder")
            alert.addButton(withTitle: "Позже")
            let response = alert.runModal()
            self.isShowingUnreadableAlert = false
            switch response {
            case .alertFirstButtonReturn:
                self.configureFileStore()
            case .alertSecondButtonReturn:
                self.settings.openFolderInFinder()
            default:
                break
            }
        }
    }

    /// The folder is there but silent, which in practice means macOS is still deciding whether this
    /// copy of the app may read it. Re-picking the folder is what answers that question.
    private func handleStalledFolder() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settings.setFolderState(.awaitingAccess)
            guard !self.hasWarnedAboutStalledFolder else { return }
            self.hasWarnedAboutStalledFolder = true

            let alert = NSAlert()
            alert.messageText = "Нет ответа от папки с заметками"
            alert.informativeText = """
            macOS не подтвердила доступ этой версии приложения к папке, и чтение стоит на месте. \
            Заметки по-прежнему пишутся в теневую копию, ничего не потеряется.

            Выберите папку ещё раз — это подтверждает доступ — или разрешите его в \
            «Системные настройки → Конфиденциальность → Файлы и папки».
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Выбрать папку")
            alert.addButton(withTitle: "Позже")
            let response = alert.runModal()
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
            let image = NSImage(systemSymbolName: "circle", accessibilityDescription: "NoteObs")?
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
        container.routeShortcuts { [weak self] window in
            guard let self, let window else { return false }
            return window === self.window || window === self.popover.contentViewController?.view.window
        }

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
        
        let headerItem = NSMenuItem(title: "Заметки NoteObs", action: nil, keyEquivalent: "")
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
        openFolderItem.isEnabled = container.settings.canOpenFolderInFinder
        menu.addItem(openFolderItem)

        let settingsItem = NSMenuItem(title: "Настройки...", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Завершить NoteObs", action: #selector(quitApp), keyEquivalent: "q")
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
            refreshFromDiskSoon()
            showWindow()
            return
        }
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            refreshFromDiskSoon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// The editor opens with whatever is already in memory; the folder read lands a moment later
    /// instead of holding up the popover.
    private func refreshFromDiskSoon() {
        Task { await container.viewModel.refreshFromDisk() }
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
        refreshFromDiskSoon()
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
        // Mirrors land first: the write below is the one that can stall on an unreachable folder,
        // and the text has to be safe before it does.
        container.viewModel.settleRecoveryForTermination()
        container.viewModel.flushPendingSaveSynchronously()
        container.viewModel.settleRecoveryForTermination()
    }

    func windowWillClose(_ notification: Notification) {
        if container.windowState.isDetached {
            container.windowState.isDetached = false
        }
    }
}
