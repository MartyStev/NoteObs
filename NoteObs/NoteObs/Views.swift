import SwiftUI

// MARK: - Color and Theme Extensions

extension NSColor {
    /// Perceived luminance / brightness using standard ITU-R BT.601 coefficients.
    var perceivedLuminance: CGFloat {
        let rgb = usingColorSpace(.deviceRGB) ?? self
        return (0.299 * rgb.redComponent) + (0.587 * rgb.greenComponent) + (0.114 * rgb.blueComponent)
    }

    var isDarkTheme: Bool {
        perceivedLuminance < 0.5
    }

    func blended(with other: NSColor, fraction: CGFloat) -> NSColor {
        let c1 = usingColorSpace(.deviceRGB) ?? self
        let c2 = other.usingColorSpace(.deviceRGB) ?? other
        let f = max(0, min(1, fraction))
        let r = c1.redComponent + (c2.redComponent - c1.redComponent) * f
        let g = c1.greenComponent + (c2.greenComponent - c1.greenComponent) * f
        let b = c1.blueComponent + (c2.blueComponent - c1.blueComponent) * f
        let a = c1.alphaComponent + (c2.alphaComponent - c1.alphaComponent) * f
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }
}

struct NoteTheme {
    let baseNSColor: NSColor
    let backgroundColor: Color
    let textColor: Color
    let secondaryTextColor: Color
    let lineColor: Color
    let inactiveRingColor: Color
    let selectionColor: NSColor

    init(baseColor: NSColor) {
        self.baseNSColor = baseColor
        let isDark = baseColor.isDarkTheme
        self.backgroundColor = Color(nsColor: baseColor)

        // Always use standard adaptive system colors for crisp text
        self.textColor = Color(nsColor: .labelColor)
        self.secondaryTextColor = Color(nsColor: .secondaryLabelColor)

        let lineNS = baseColor.blended(with: isDark ? .white : .black, fraction: isDark ? 0.32 : 0.25)
        let inactiveNS = baseColor.blended(with: isDark ? .white : .black, fraction: isDark ? 0.22 : 0.2)

        // Accent selection color tinted with the window theme color (20% darker & more saturated)
        let selNS = baseColor.blended(with: .black, fraction: isDark ? 0.20 : 0.45)
            .withAlphaComponent(isDark ? 0.65 : 0.55)

        self.lineColor = Color(nsColor: lineNS.withAlphaComponent(0.6))
        self.inactiveRingColor = Color(nsColor: inactiveNS)
        self.selectionColor = selNS
    }
}

// MARK: - Visual Effect View (Frosted Glass / Vibrancy)

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @ObservedObject var viewModel: NotesViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var windowState: WindowState

    private var theme: NoteTheme {
        NoteTheme(baseColor: settings.themeColor)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                VisualEffectView(material: settings.blurMaterial.nsMaterial, blendingMode: .behindWindow)
                theme.backgroundColor.opacity(settings.backgroundOpacity)

                if settings.isEditorUsable {
                    VStack(spacing: 6) {
                        HeaderBarView(
                            viewModel: viewModel,
                            windowState: windowState,
                            theme: theme
                        )
                        .padding(.top, 6)
                        .padding(.horizontal, 10)

                        if !settings.isFolderReady {
                            FolderNoticeView(settings: settings, textColor: theme.textColor)
                                .padding(.horizontal, 10)
                        }

                        NoteEditorView(
                            viewModel: viewModel,
                            settings: settings,
                            theme: theme
                        )
                        .padding([.horizontal, .bottom], 6)
                    }
                } else {
                    EmptyFolderStateView(
                        settings: settings,
                        textColor: theme.textColor
                    )
                }
            }

            // Corner resize handle (bottom-right)
            ResizeCornerHandle(settings: settings)
                .padding(2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.lineColor.opacity(0.2), lineWidth: 0.5)
        )
        .tint(theme.textColor)
        .frame(
            minWidth: 440,
            idealWidth: CGFloat(settings.windowWidth),
            maxWidth: .infinity,
            minHeight: 280,
            idealHeight: CGFloat(settings.windowHeight),
            maxHeight: .infinity
        )
    }
}

// MARK: - Header & Navigation Subviews

struct HeaderBarView: View {
    @ObservedObject var viewModel: NotesViewModel
    @ObservedObject var windowState: WindowState
    let theme: NoteTheme

    var body: some View {
        ZStack {
            DragHandleView()
                .frame(height: 28)

            HStack {
                Spacer()
                SlotSelectorView(
                    slots: viewModel.slots,
                    selectedIndex: viewModel.selectedIndex,
                    theme: theme,
                    onSelect: { index in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            viewModel.select(index: index)
                        }
                    }
                )
                Spacer()
            }

            HStack {
                Spacer()
                WindowActionsView(windowState: windowState, theme: theme)
            }

            HStack {
                if viewModel.isSaveFailing {
                    Label("не сохраняется", systemImage: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Текст ещё не записан в папку заметок. Он сохранён отдельно и будет записан, когда папка ответит.")
                }
                Spacer()
            }
        }
    }
}

struct SlotSelectorView: View {
    let slots: [NoteSlot]
    let selectedIndex: Int
    let theme: NoteTheme
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(slots) { slot in
                let isActive = selectedIndex == slot.id
                let hasContent = !slot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let slotColor = Color(slot.color)

                Button {
                    onSelect(slot.id)
                } label: {
                    ZStack(alignment: .center) {
                        // Outer ring using strokeBorder for pixel-perfect integer alignment
                        Circle()
                            .strokeBorder(
                                isActive ? slotColor : (hasContent ? slotColor.opacity(0.7) : theme.inactiveRingColor),
                                lineWidth: 2
                            )
                            .frame(width: 16, height: 16)

                        // Centered inner indicator with exact integer margins
                        if isActive {
                            Circle()
                                .fill(slotColor)
                                .frame(width: 8, height: 8)
                        } else if hasContent {
                            Circle()
                                .fill(slotColor.opacity(0.85))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 28, height: 28, alignment: .center)
                    .contentShape(Rectangle())
                    .scaleEffect(isActive ? 1.15 : 1.0)
                    .shadow(color: isActive ? slotColor.opacity(0.5) : .clear, radius: 4, x: 0, y: 0)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct WindowActionsView: View {
    @ObservedObject var windowState: WindowState
    let theme: NoteTheme

    var body: some View {
        HStack(spacing: 6) {
            HeaderIconButton(
                systemName: windowState.isDetached ? "arrow.down.right.square" : "arrow.up.right.square",
                tooltip: windowState.isDetached ? "Встроить в строку меню" : "Открыть в отдельном окне",
                theme: theme,
                action: { windowState.isDetached.toggle() }
            )

            HeaderIconButton(
                systemName: windowState.isPinned ? "pin.fill" : "pin",
                tooltip: "Закрепить поверх всех окон",
                theme: theme,
                disabled: !windowState.isDetached,
                action: { windowState.isPinned.toggle() }
            )

            HeaderIconButton(
                systemName: "gearshape",
                tooltip: "Настройки",
                theme: theme,
                action: { NotificationCenter.default.post(name: .openSettingsWindow, object: nil) }
            )
        }
    }
}

struct HeaderIconButton: View {
    let systemName: String
    let tooltip: String
    let theme: NoteTheme
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovered ? theme.lineColor.opacity(0.2) : Color.clear)
                    .frame(width: 24, height: 24)

                SymbolImage(name: systemName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(disabled ? Color.secondary.opacity(0.3) : (isHovered ? Color.primary : Color.secondary.opacity(0.8)))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(tooltip)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Editor Subviews

struct NoteEditorView: View {
    @ObservedObject var viewModel: NotesViewModel
    @ObservedObject var settings: AppSettings
    let theme: NoteTheme

    private var currentText: String {
        guard viewModel.slots.indices.contains(viewModel.selectedIndex) else { return "" }
        return viewModel.slots[viewModel.selectedIndex].text
    }

    var body: some View {
        let isDark = theme.baseNSColor.isDarkTheme

        MarkdownTextView(
            text: Binding(
                get: { currentText },
                set: { viewModel.updateText($0) }
            ),
            theme: theme,
            font: settings.fontFamily.nsFont(size: CGFloat(settings.fontSize))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDark ? Color.black.opacity(0.28) : Color.white.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(isDark ? 0.18 : 0.06), radius: 4, x: 0, y: 1)
    }
}

// MARK: - Interactive Markdown Text View (AppKit)

final class CustomScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override func tile() {
        super.tile()
        if scrollerStyle != .overlay {
            scrollerStyle = .overlay
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollerStyle = .overlay
        verticalScroller?.scrollerStyle = .overlay
        verticalScroller?.controlSize = .small
    }
}

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let theme: NoteTheme
    let font: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CustomScrollView {
        let scrollView = CustomScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .default
        if let verticalScroller = scrollView.verticalScroller {
            verticalScroller.controlSize = .small
        }

        let textView = NSTextViewCustom()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor.labelColor
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selectionColor
        ]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.onToggleCheckboxShortcut = { [weak coordinator = context.coordinator] in
            coordinator?.toggleCurrentLineCheckbox()
        }

        context.coordinator.textView = textView
        context.coordinator.applyMarkdownStyling(to: textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: CustomScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextViewCustom else { return }
        context.coordinator.parent = self

        // Rewriting the buffer under an active input-method composition drops the pending
        // characters, so leave the text alone until the composition settles.
        if textView.string != text, !textView.hasMarkedText() {
            let newLength = (text as NSString).length
            let selectedRanges = Self.clamp(textView.selectedRanges, toLength: newLength)
            textView.string = text
            textView.selectedRanges = selectedRanges
            // The buffer now holds another note, or the folder's newer copy. Undo steps recorded
            // against the old text would replay at offsets that mean something else here.
            textView.undoManager?.removeAllActions()
            context.coordinator.applyMarkdownStyling(to: textView, forcingFullPass: true)
        }

        // These run on every keystroke, and setting the font re-attributes the whole document, so
        // they are only touched when they actually change.
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != NSColor.labelColor {
            textView.textColor = NSColor.labelColor
            textView.insertionPointColor = NSColor.labelColor
        }
        if textView.selectedTextAttributes[.backgroundColor] as? NSColor != theme.selectionColor {
            textView.selectedTextAttributes = [
                .backgroundColor: theme.selectionColor
            ]
        }
    }

    private static func clamp(_ selectedRanges: [Any], toLength length: Int) -> [NSValue] {
        let clamped = selectedRanges.compactMap { value -> NSValue? in
            guard let range = (value as? NSValue)?.rangeValue else { return nil }
            let location = min(max(0, range.location), length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        return clamped.isEmpty ? [NSValue(range: NSRange(location: length, length: 0))] : clamped
    }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextViewCustom?
        private var stylingTracker = MarkdownStylingTracker()

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextViewCustom else { return }
            let newText = textView.string
            if parent.text != newText {
                parent.text = newText
            }
            applyMarkdownStyling(to: textView)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            } else if let string = link as? String, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        func toggleCurrentLineCheckbox() {
            guard let textView else { return }
            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let lineRange = nsString.lineRange(for: selectedRange)
            let line = nsString.substring(with: lineRange)
            let newLine = Checklist.toggled(line)

            if textView.shouldChangeText(in: lineRange, replacementString: newLine) {
                textView.replaceCharacters(in: lineRange, with: newLine)
                textView.didChangeText()
            }
        }

        /// Styling is incremental: a keystroke re-attributes its own paragraph, plus the one after it
        /// when the edit moved a line break. A first pass, a font swap, a slot switch or a change
        /// bigger than the tracker's threshold re-attributes the whole document.
        func applyMarkdownStyling(to textView: NSTextView, forcingFullPass: Bool = false) {
            guard let textStorage = textView.textStorage else { return }
            // Re-attributing the buffer mid-composition discards pending input-method characters.
            guard !textView.hasMarkedText() else { return }
            let current = textStorage.string as NSString
            guard let target = stylingTracker.rangeToRestyle(
                in: current,
                font: parent.font,
                forcingFullPass: forcingFullPass
            ) else { return }

            MarkdownStyling.applyStyling(
                to: textStorage,
                text: current,
                target: target,
                font: parent.font,
                color: NSColor.labelColor
            )
        }
    }
}

final class NSTextViewCustom: NSTextView {
    var onToggleCheckboxShortcut: (() -> Void)?

    private static let keyCodeC: UInt16 = 8

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd + Shift + C toggles a checkbox. Matched by key position, not character: on the Russian
        // layout the same key types "с", and the shortcut has to work there too.
        if flags == [.command, .shift] && event.keyCode == Self.keyCodeC {
            onToggleCheckboxShortcut?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        let hitIndex = characterIndex(under: point)

        // Multi-click selects words and paragraphs, Shift extends the selection, Control opens the
        // context menu: all of that is the text view's own behaviour.
        if event.clickCount > 1 || !event.modifierFlags.isDisjoint(with: [.shift, .control]) {
            super.mouseDown(with: event)
            return
        }

        if let hitIndex, toggleCheckbox(at: hitIndex) {
            return
        }
        let link = hitIndex.flatMap { textStorage?.attribute(.link, at: $0, effectiveRange: nil) }

        // Direct tracking loop: clicking anywhere (even inside existing selection) immediately starts a new range selection
        setSelectedRange(NSRange(location: charIndex, length: 0))
        let anchorIndex = charIndex

        guard let window else {
            super.mouseDown(with: event)
            return
        }

        var keepTracking = true
        var didDrag = false
        while keepTracking {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            switch nextEvent.type {
            case .leftMouseDragged:
                didDrag = true
                let dragPoint = convert(nextEvent.locationInWindow, from: nil)
                let currentIndex = characterIndexForInsertion(at: dragPoint)
                let start = min(anchorIndex, currentIndex)
                let length = abs(currentIndex - anchorIndex)
                setSelectedRange(NSRange(location: start, length: length))
                scrollRangeToVisible(NSRange(location: currentIndex, length: 0))

            case .leftMouseUp:
                keepTracking = false
                // A click that did not turn into a selection follows the link under it, as a link
                // in any other text view would.
                if !didDrag, let link, let hitIndex {
                    clicked(onLink: link, at: hitIndex)
                }

            default:
                break
            }
        }
    }

    /// The character drawn under `point`, or nil over empty space — unlike the insertion index,
    /// which always answers with the nearest caret position.
    private func characterIndex(under point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return index < (string as NSString).length ? index : nil
    }

    /// Toggles the checklist item whose box is under the click. Answers whether it did.
    private func toggleCheckbox(at index: Int) -> Bool {
        let nsString = string as NSString
        let lineRange = nsString.lineRange(for: NSRange(location: index, length: 0))
        let line = nsString.substring(with: lineRange)
        guard let box = Checklist.boxRange(in: line),
              NSLocationInRange(index - lineRange.location, box) else { return false }
        let newLine = Checklist.toggled(line)
        guard shouldChangeText(in: lineRange, replacementString: newLine) else { return false }
        replaceCharacters(in: lineRange, with: newLine)
        didChangeText()
        return true
    }

    override func dragSelection(with event: NSEvent, offset: NSSize, slideBack: Bool) -> Bool {
        return false
    }
}

// MARK: - Empty State and Borders

/// A strip above the editor for the one folder state that still lets the user work: the notes are
/// open, the folder simply has not answered yet.
struct FolderNoticeView: View {
    @ObservedObject var settings: AppSettings
    let textColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.marks.rectangle")
                .font(.system(size: 11))
            Text("Доступ к папке ещё не подтверждён. Текст сохраняется в теневую копию.")
                .font(.system(size: 11))
                .foregroundColor(textColor.opacity(0.8))
            Spacer(minLength: 6)
            Button("Проверить") {
                settings.retryFolderAccess()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(textColor.opacity(0.08))
        )
    }
}

struct EmptyFolderStateView: View {
    @ObservedObject var settings: AppSettings
    let textColor: Color

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(textColor.opacity(0.7))
            if settings.hasFolderSelection {
                Text(settings.notesFolderPath)
                    .font(.system(size: 11))
                    .foregroundColor(textColor.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if settings.folderState == .unreadableNotes {
                // The folder is right; its files need repair or the sync to finish.
                HStack(spacing: 8) {
                    Button("Проверить снова") {
                        settings.retryFolderAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Открыть в Finder") {
                        settings.openFolderInFinder()
                    }
                }
            } else {
                Button(buttonTitle) {
                    settings.promptForFolder()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var title: String {
        switch settings.folderState {
        case .unconfigured: return "Папка для заметок не выбрана"
        case .available: return ""
        case .awaitingAccess: return ""
        case .inaccessible: return "Не удается получить доступ к папке заметок"
        case .unreadableNotes: return "Некоторые заметки в папке не читаются"
        }
    }

    private var message: String {
        switch settings.folderState {
        case .unconfigured: return "Выберите папку в настройках."
        case .available: return ""
        case .awaitingAccess: return "macOS ещё не разрешила доступ к папке."
        case .inaccessible: return "Выберите папку заново или проверьте права доступа."
        case .unreadableNotes: return "Запись в папку остановлена, чтобы не затереть эти файлы."
        }
    }

    private var buttonTitle: String {
        switch settings.folderState {
        case .unconfigured: return "Выбрать папку"
        case .available: return ""
        case .awaitingAccess: return "Выбрать папку заново"
        case .inaccessible: return "Выбрать другую папку"
        case .unreadableNotes: return ""
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 14) {
            // Folder Section
            SettingsCardView(title: "Папка заметок", icon: "folder.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(settings.hasFolderSelection ? settings.notesFolderPath : "Папка не выбрана")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button("Выбрать папку") {
                            settings.promptForFolder()
                        }
                        Button("Открыть в Finder") {
                            settings.openFolderInFinder()
                        }
                        .disabled(!settings.canOpenFolderInFinder)
                    }
                }
            }

            // Typography Section
            SettingsCardView(title: "Шрифт и текст", icon: "textformat") {
                VStack(spacing: 10) {
                    HStack {
                        Text("Гарнитура:")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $settings.fontFamily) {
                            ForEach(AppFontFamily.allCases) { family in
                                Text(family.displayName).tag(family)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }

                    HStack {
                        Text("Размер шрифта:")
                            .font(.system(size: 12))
                        Spacer()
                        Stepper(value: $settings.fontSize, in: 11...24, step: 1) {
                            Text("\(Int(settings.fontSize)) pt")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                }
            }

            // Appearance & Transparency Section
            SettingsCardView(title: "Внешний вид и прозрачность", icon: "paintpalette.fill") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Цвет темы окна:")
                            .font(.system(size: 12))
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: settings.themeColor) },
                            set: { settings.setThemeColor(from: $0) }
                        ))
                        .labelsHidden()
                    }

                    HStack {
                        Text("Стиль матового стекла:")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $settings.blurMaterial) {
                            ForEach(BlurMaterial.allCases) { material in
                                Text(material.displayName).tag(material)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    HStack {
                        Text("Непрозрачность цвета:")
                            .font(.system(size: 12))
                        Spacer()
                        Slider(value: $settings.backgroundOpacity, in: 0.0...1.0, step: 0.05)
                            .frame(width: 130)
                        Text("\(Int(round(settings.backgroundOpacity * 100)))%")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            // Window Dimensions Section
            SettingsCardView(title: "Размер окна и панели", icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left") {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Button("560 × 360") {
                            settings.windowWidth = 560
                            settings.windowHeight = 360
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("720 × 420") {
                            settings.windowWidth = 720
                            settings.windowHeight = 420
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("900 × 560") {
                            settings.windowWidth = 900
                            settings.windowHeight = 560
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }

                    HStack {
                        Text("Ширина:")
                            .font(.system(size: 12))
                        Spacer()
                        Stepper(value: $settings.windowWidth, in: 440...1400, step: 20) {
                            Text("\(Int(settings.windowWidth)) px")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                        }
                    }

                    HStack {
                        Text("Высота:")
                            .font(.system(size: 12))
                        Spacer()
                        Stepper(value: $settings.windowHeight, in: 280...1000, step: 20) {
                            Text("\(Int(settings.windowHeight)) px")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                }
            }

            // System Section
            SettingsCardView(title: "Система", icon: "gearshape.fill") {
                Toggle("Запускать при входе в систему", isOn: $settings.launchAtLoginEnabled)
                    .font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

struct SettingsCardView<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
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

struct ResizeCornerHandle: View {
    @ObservedObject var settings: AppSettings
    @State private var dragInitialSize: CGSize?
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(-45))
            .frame(width: 14, height: 14)
            .opacity(isHovered ? 0.6 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        if dragInitialSize == nil {
                            dragInitialSize = CGSize(width: settings.windowWidth, height: settings.windowHeight)
                        }
                        guard let initial = dragInitialSize else { return }
                        let newW = max(440, min(1400, initial.width + gesture.translation.width))
                        let newH = max(280, min(1000, initial.height + gesture.translation.height))
                        settings.windowWidth = newW
                        settings.windowHeight = newH
                    }
                    .onEnded { _ in
                        dragInitialSize = nil
                    }
            )
    }
}


