import AppKit
import Combine
import SwiftUI

enum NotesFolderState {
    case unconfigured
    case available
    case inaccessible
}

enum AppFontFamily: String, CaseIterable, Identifiable {
    case monospaced = "monospaced"
    case system = "system"
    case serif = "serif"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .monospaced: return "Моноширинный"
        case .system: return "Системный"
        case .serif: return "С засечками"
        }
    }

    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .system:
            return NSFont.systemFont(ofSize: size, weight: .regular)
        case .serif:
            if let serifFont = NSFont(name: "Georgia", size: size) {
                return serifFont
            }
            return NSFont.systemFont(ofSize: size, weight: .regular)
        }
    }
}

enum BlurMaterial: String, CaseIterable, Identifiable {
    case hud = "hud"
    case underWindow = "underWindow"
    case popover = "popover"
    case menu = "menu"
    case sidebar = "sidebar"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hud: return "Тёмное стекло (HUD)"
        case .underWindow: return "Системное (Under Window)"
        case .popover: return "Всплывающее (Popover)"
        case .menu: return "Меню (Menu)"
        case .sidebar: return "Боковая панель (Sidebar)"
        }
    }

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .hud: return .hudWindow
        case .underWindow: return .underWindowBackground
        case .popover: return .popover
        case .menu: return .menu
        case .sidebar: return .sidebar
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var notesFolderPath: String {
        didSet {
            UserDefaults.standard.set(notesFolderPath, forKey: Self.userDefaultsKey)
        }
    }

    @Published private(set) var folderState: NotesFolderState

    @Published var themeColor: NSColor {
        didSet {
            UserDefaults.standard.set(Self.encodeColor(themeColor), forKey: Self.themeColorKey)
        }
    }

    @Published var fontSize: Double {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: Self.fontSizeKey)
        }
    }

    @Published var fontFamily: AppFontFamily {
        didSet {
            UserDefaults.standard.set(fontFamily.rawValue, forKey: Self.fontFamilyKey)
        }
    }

    @Published var showWordCount: Bool {
        didSet {
            UserDefaults.standard.set(showWordCount, forKey: Self.showWordCountKey)
        }
    }

    @Published var backgroundOpacity: Double {
        didSet {
            UserDefaults.standard.set(backgroundOpacity, forKey: Self.backgroundOpacityKey)
        }
    }

    @Published var blurMaterial: BlurMaterial {
        didSet {
            UserDefaults.standard.set(blurMaterial.rawValue, forKey: Self.blurMaterialKey)
        }
    }

    @Published var windowWidth: Double {
        didSet {
            UserDefaults.standard.set(windowWidth, forKey: Self.windowWidthKey)
        }
    }

    @Published var windowHeight: Double {
        didSet {
            UserDefaults.standard.set(windowHeight, forKey: Self.windowHeightKey)
        }
    }

    @Published var launchAtLoginEnabled: Bool {
        didSet {
            guard !isInternalLaunchAtLoginUpdate else { return }
            let desired = launchAtLoginEnabled
            let previous = oldValue

            UserDefaults.standard.set(desired, forKey: Self.launchAtLoginKey)

            launchAtLoginApplyTask?.cancel()
            launchAtLoginApplyTask = Task { @MainActor in
                do {
                    try LaunchAtLoginManager.setEnabled(desired)
                } catch {
                    await presentLaunchAtLoginError(error)
                    isInternalLaunchAtLoginUpdate = true
                    launchAtLoginEnabled = previous
                    UserDefaults.standard.set(previous, forKey: Self.launchAtLoginKey)
                    isInternalLaunchAtLoginUpdate = false
                }
            }
        }
    }

    static let userDefaultsKey = "notesFolderPath"
    static let bookmarkKey = "notesFolderBookmark"
    static let themeColorKey = "themeColorRGBA"
    static let launchAtLoginKey = "launchAtLoginEnabled"
    static let fontSizeKey = "editorFontSize"
    static let fontFamilyKey = "editorFontFamily"
    static let showWordCountKey = "showWordCount"
    static let backgroundOpacityKey = "backgroundOpacity"
    static let blurMaterialKey = "blurMaterial"
    static let windowWidthKey = "windowWidth"
    static let windowHeightKey = "windowHeight"

    private var isInternalLaunchAtLoginUpdate = false
    private var launchAtLoginApplyTask: Task<Void, Never>?

    init() {
        var resolvedPath = ""
        var initialFolderState: NotesFolderState = .unconfigured

        // Resolve Security-Scoped Bookmark if available
        if let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var isStale = false
            do {
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    if let newBookmark = try? resolvedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        UserDefaults.standard.set(newBookmark, forKey: Self.bookmarkKey)
                    }
                }
                resolvedPath = resolvedURL.path
                initialFolderState = .inaccessible
            } catch {
                resolvedPath = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
                initialFolderState = resolvedPath.isEmpty ? .unconfigured : .inaccessible
            }
        } else {
            resolvedPath = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
            initialFolderState = resolvedPath.isEmpty ? .unconfigured : .inaccessible
        }

        notesFolderPath = resolvedPath
        folderState = initialFolderState

        if let stored = UserDefaults.standard.array(forKey: Self.themeColorKey) as? [Double],
           let color = Self.decodeColor(stored) {
            themeColor = color
        } else {
            themeColor = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.09, alpha: 1.0)
        }

        let storedSize = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        fontSize = storedSize >= 10 ? storedSize : 14.0

        if let rawFamily = UserDefaults.standard.string(forKey: Self.fontFamilyKey),
           let family = AppFontFamily(rawValue: rawFamily) {
            fontFamily = family
        } else {
            fontFamily = .monospaced
        }

        if UserDefaults.standard.object(forKey: Self.showWordCountKey) != nil {
            showWordCount = UserDefaults.standard.bool(forKey: Self.showWordCountKey)
        } else {
            showWordCount = true
        }

        if UserDefaults.standard.object(forKey: Self.backgroundOpacityKey) != nil {
            let op = UserDefaults.standard.double(forKey: Self.backgroundOpacityKey)
            backgroundOpacity = min(1.0, max(0.0, op))
        } else {
            backgroundOpacity = 0.35
        }

        if let rawBlur = UserDefaults.standard.string(forKey: Self.blurMaterialKey),
           let material = BlurMaterial(rawValue: rawBlur) {
            blurMaterial = material
        } else {
            blurMaterial = .popover
        }

        let storedWidth = UserDefaults.standard.double(forKey: Self.windowWidthKey)
        windowWidth = storedWidth >= 400 ? storedWidth : 720.0

        let storedHeight = UserDefaults.standard.double(forKey: Self.windowHeightKey)
        windowHeight = storedHeight >= 260 ? storedHeight : 420.0

        launchAtLoginEnabled = UserDefaults.standard.object(forKey: Self.launchAtLoginKey) as? Bool ?? false
    }

    var hasFolderSelection: Bool {
        !notesFolderPath.isEmpty
    }

    var isFolderReady: Bool {
        folderState == .available
    }

    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Выберите папку для хранения заметок"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            // Save Security-Scoped Bookmark
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            }
            self?.notesFolderPath = url.path
        }
    }

    func openFolderInFinder() {
        guard isFolderReady else { return }
        let url = URL(fileURLWithPath: notesFolderPath, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    func setThemeColor(from color: Color) {
        themeColor = NSColor(color)
    }

    func setFolderState(_ state: NotesFolderState) {
        folderState = state
    }

    func applyLaunchAtLoginPreferenceOnLaunch() {
        let desired = launchAtLoginEnabled
        Task { @MainActor in
            do {
                try LaunchAtLoginManager.setEnabled(desired)
            } catch {
                await presentLaunchAtLoginError(error)
                isInternalLaunchAtLoginUpdate = true
                launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
                UserDefaults.standard.set(launchAtLoginEnabled, forKey: Self.launchAtLoginKey)
                isInternalLaunchAtLoginUpdate = false
            }
        }
    }

    private static func encodeColor(_ color: NSColor) -> [Double] {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)]
    }

    private static func decodeColor(_ components: [Double]) -> NSColor? {
        guard components.count == 4 else { return nil }
        return NSColor(
            calibratedRed: CGFloat(components[0]),
            green: CGFloat(components[1]),
            blue: CGFloat(components[2]),
            alpha: CGFloat(components[3])
        )
    }

    private func presentLaunchAtLoginError(_ error: Error) async {
        let alert = NSAlert()
        alert.messageText = "Не удалось настроить автозапуск"
        alert.informativeText = "macOS отклонила запрос на добавление приложения в автозапуск.\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

