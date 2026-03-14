import AppKit
import Combine
import SwiftUI

enum NotesFolderState {
    case unconfigured
    case available
    case inaccessible
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

    static let userDefaultsKey = "notesFolderPath"
    static let themeColorKey = "themeColorRGBA"

    init() {
        let storedPath = UserDefaults.standard.string(forKey: Self.userDefaultsKey) ?? ""
        notesFolderPath = storedPath
        folderState = storedPath.isEmpty ? .unconfigured : .inaccessible
        if let stored = UserDefaults.standard.array(forKey: Self.themeColorKey) as? [Double],
           let color = Self.decodeColor(stored) {
            themeColor = color
        } else {
            themeColor = NSColor(calibratedRed: 0.17, green: 0.16, blue: 0.09, alpha: 1.0)
        }
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
}
