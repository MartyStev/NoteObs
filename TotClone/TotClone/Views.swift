import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: NotesViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var windowState: WindowState

    var body: some View {
        let baseNS = settings.themeColor.usingColorSpace(.deviceRGB) ?? settings.themeColor
        let brightness = (0.299 * baseNS.redComponent) + (0.587 * baseNS.greenComponent) + (0.114 * baseNS.blueComponent)
        let isDark = brightness < 0.5
        let backgroundColor = Color(nsColor: baseNS)
        let textNS = isDark ? NSColor(calibratedWhite: 0.93, alpha: 1.0) : NSColor(calibratedWhite: 0.12, alpha: 1.0)
        let lineNS = blend(baseNS, with: isDark ? .white : .black, fraction: isDark ? 0.32 : 0.25)
        let inactiveNS = blend(baseNS, with: isDark ? .white : .black, fraction: isDark ? 0.22 : 0.2)
        let textColor = Color(nsColor: textNS)
        let lineColor = Color(nsColor: lineNS.withAlphaComponent(0.7))
        let inactiveRing = Color(nsColor: inactiveNS)

        ZStack {
            backgroundColor
            if settings.isFolderReady {
                VStack(spacing: 12) {
                    ZStack {
                        DragHandleView()
                            .frame(height: 24)

                        HStack {
                            Spacer()
                            HStack(spacing: 12) {
                                ForEach(viewModel.slots) { slot in
                                    let isActive = viewModel.selectedIndex == slot.id
                                    Button {
                                        viewModel.select(index: slot.id)
                                    } label: {
                                        Circle()
                                            .fill(backgroundColor)
                                            .frame(width: 14, height: 14)
                                            .overlay(
                                                Circle()
                                                    .stroke(isActive ? Color(slot.color) : inactiveRing, lineWidth: isActive ? 2.5 : 2)
                                            )
                                            .shadow(color: isActive ? Color(slot.color).opacity(0.35) : .clear, radius: 6, x: 0, y: 0)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Spacer()
                        }

                        HStack {
                            Spacer()
                            HStack(spacing: 8) {
                                Button {
                                    windowState.isDetached.toggle()
                                } label: {
                                    SymbolImage(name: windowState.isDetached ? "arrow.down.right.square" : "arrow.up.right.square")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)

                                Button {
                                    windowState.isPinned.toggle()
                                } label: {
                                    SymbolImage(name: windowState.isPinned ? "pin.fill" : "pin")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                                .disabled(!windowState.isDetached)

                                Button {
                                    openSettings()
                                } label: {
                                    SymbolImage(name: "gearshape")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 12)

                    TextEditor(text: Binding(
                        get: {
                            guard viewModel.slots.indices.contains(viewModel.selectedIndex) else { return "" }
                            return viewModel.slots[viewModel.selectedIndex].text
                        },
                        set: { viewModel.updateText($0) }
                    ))
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundColor(textColor)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(backgroundColor)
                    .overlay(
                        Rectangle()
                            .stroke(lineColor, lineWidth: 1)
                    )
                    .padding([.leading, .trailing, .bottom], 12)
                }
            } else {
                VStack(spacing: 10) {
                    Text(emptyStateTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)
                    Text(emptyStateMessage)
                        .font(.system(size: 12))
                        .foregroundColor(textColor.opacity(0.7))
                    if settings.hasFolderSelection {
                        Text(settings.notesFolderPath)
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    Button(emptyStateButtonTitle) {
                        settings.promptForFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
            }

            VStack {
                HStack {
                    Rectangle().fill(lineColor).frame(width: 1)
                    Spacer()
                    Rectangle().fill(lineColor).frame(width: 1)
                }
                Spacer()
                Rectangle().fill(lineColor).frame(height: 1)
            }
        }
        .tint(textColor)
        .frame(minWidth: 520, idealWidth: 720, minHeight: 320, idealHeight: 420)
        .background(
            KeyCaptureView { direction in
                switch direction {
                case .left:
                    viewModel.moveSelection(delta: -1)
                case .right:
                    viewModel.moveSelection(delta: 1)
                }
            }
        )
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    private var emptyStateTitle: String {
        switch settings.folderState {
        case .unconfigured:
            return "Папка для заметок не выбрана"
        case .available:
            return ""
        case .inaccessible:
            return "Не удается получить доступ к папке заметок"
        }
    }

    private var emptyStateMessage: String {
        switch settings.folderState {
        case .unconfigured:
            return "Выберите папку в настройках."
        case .available:
            return ""
        case .inaccessible:
            return "Выберите папку заново или проверьте права доступа."
        }
    }

    private var emptyStateButtonTitle: String {
        switch settings.folderState {
        case .unconfigured:
            return "Выбрать папку"
        case .available:
            return ""
        case .inaccessible:
            return "Выбрать другую папку"
        }
    }

    private func blend(_ color: NSColor, with other: NSColor, fraction: CGFloat) -> NSColor {
        let c1 = color.usingColorSpace(.deviceRGB) ?? color
        let c2 = other.usingColorSpace(.deviceRGB) ?? other
        let f = max(0, min(1, fraction))
        let r = c1.redComponent + (c2.redComponent - c1.redComponent) * f
        let g = c1.greenComponent + (c2.greenComponent - c1.greenComponent) * f
        let b = c1.blueComponent + (c2.blueComponent - c1.blueComponent) * f
        let a = c1.alphaComponent + (c2.alphaComponent - c1.alphaComponent) * f
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

enum ArrowDirection {
    case left
    case right
}

struct KeyCaptureView: NSViewRepresentable {
    let onArrow: (ArrowDirection) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onArrow = onArrow
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onArrow = onArrow
    }
}

final class KeyCaptureNSView: NSView {
    var onArrow: ((ArrowDirection) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            onArrow?(.left)
        case 124:
            onArrow?(.right)
        default:
            super.keyDown(with: event)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Папка заметок")
                .font(.system(size: 13, weight: .semibold))

            Text(settings.hasFolderSelection ? settings.notesFolderPath : "Не выбрано")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Выбрать папку") {
                    settings.promptForFolder()
                }
                Button("Открыть папку") {
                    settings.openFolderInFinder()
                }
                .disabled(!settings.isFolderReady)
            }

            Divider()

            ColorPicker("Цвет окна", selection: Binding(
                get: { Color(nsColor: settings.themeColor) },
                set: { settings.setThemeColor(from: $0) }
            ))
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct SymbolImage: View {
    let name: String

    var body: some View {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            Image(nsImage: image)
        } else if let fallback = NSImage(systemSymbolName: "square", accessibilityDescription: nil) {
            Image(nsImage: fallback)
        } else {
            EmptyView()
        }
    }
}

struct DragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView {
        DragHandleNSView()
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

final class DragHandleNSView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let selector = NSSelectorFromString("performWindowDragWithEvent:")
        if window.responds(to: selector) {
            _ = window.perform(selector, with: event)
        }
    }
}
