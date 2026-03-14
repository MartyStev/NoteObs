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

class CircleIcon: NSView {
    // Устанавливаем большой размер для кликабельной области
    override var intrinsicContentSize: NSSize { NSSize(width: 15, height: 15) }
    
    // Определяем, активна ли иконка
    private var isActive: Bool {
        // Проверяем различные условия активности
        return NSApp.isActive ||
               (self.window?.isKeyWindow ?? false) ||
               NSScreen.main == self.window?.screen
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupNotifications()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupNotifications()
    }
    
    private func setupNotifications() {
        // Следим за изменениями активности приложения
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        
        // Следим за изменениями ключевого окна
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        
        // Следим за изменениями экрана
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
    }
    
    @objc private func redraw() {
        needsDisplay = true
    }
    
    override func draw(_ rect: NSRect) {
        let bounds = self.bounds
        
        // Используем разные цвета в зависимости от активности
        if isActive {
            NSColor.labelColor.setStroke() // Черный в светлой теме, белый в темной
        } else {
            // В неактивном состоянии используем полупрозрачный цвет
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
        }
        
        // Рисуем круг стандартного размера
        let circleSize: CGFloat = 17
        let circleRect = NSRect(
            x: (bounds.width - circleSize) / 2,
            y: (bounds.height - circleSize) / 2,
            width: circleSize,
            height: circleSize
        )
        
        let path = NSBezierPath(ovalIn: circleRect.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2.5
        path.stroke()
    }
    
    // Переопределяем для обработки кликов
    override func mouseDown(with event: NSEvent) {
        // Вызываем action у родительской кнопки
        if let button = superview as? NSButton {
            button.performClick(nil)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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
        
        // Устанавливаем фиксированную ширину для статус-бара
        statusItem = NSStatusBar.system.statusItem(withLength: 22) // Увеличил до 28 для лучшей кликабельности
        
        if let button = statusItem.button {
            let circle = CircleIcon()
            circle.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(circle)
            
            NSLayoutConstraint.activate([
                circle.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                circle.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                circle.widthAnchor.constraint(equalToConstant: 20), // Полный размер для кликов
                circle.heightAnchor.constraint(equalToConstant: 20)
            ])
            
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        // Добавляем наблюдатель для обновления иконки при изменении активности
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusIcon),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusIcon),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

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

        container.settings.applyLaunchAtLoginPreferenceOnLaunch()
    }
    
    @objc private func updateStatusIcon() {
        // Принудительно обновляем иконку
        statusItem.button?.needsDisplay = true
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
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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
