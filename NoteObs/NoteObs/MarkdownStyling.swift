import AppKit

/// The thinking behind markdown styling, kept apart from the text view so it can be checked
/// without a running app: which span of the document a change actually touches, and which spans
/// inside that range are links.
enum MarkdownStyling {
    static let linkRegex = try? NSRegularExpression(
        pattern: #"(?:https?://|obsidian://|mailto:)[^\s<>"'`]+"#,
        options: .caseInsensitive
    )

    /// A single change bigger than this is treated as a document replacement, not typing.
    static let fullPassChangeThreshold = 4_096

    /// Link spans inside `range`, whose attributes are the only ones this app derives from content.
    static func linkRanges(in text: NSString, scanning range: NSRange) -> [NSRange] {
        guard range.length > 0, let regex = linkRegex else { return [] }
        return regex.matches(in: text as String, range: range).map(\.range)
    }

    /// Re-attributes `target`: plain colour and font first, then the links found inside it. Old link
    /// attributes are cleared in the same pass, so deleting a URL also removes its styling.
    static func applyStyling(
        to textStorage: NSTextStorage,
        text: NSString,
        target: NSRange,
        font: NSFont,
        color: NSColor
    ) {
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: color, range: target)
        textStorage.addAttribute(.font, value: font, range: target)
        textStorage.removeAttribute(.link, range: target)
        textStorage.removeAttribute(.underlineStyle, range: target)

        for range in linkRanges(in: text, scanning: target) {
            guard let url = URL(string: text.substring(with: range)) else { continue }
            textStorage.addAttribute(.link, value: url, range: range)
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        textStorage.endEditing()
    }

    /// The UTF-16 span where `current` differs from `previous`.
    static func changedRange(in current: NSString, previous: NSString) -> NSRange {
        let shared = min(current.length, previous.length)
        var prefix = 0
        while prefix < shared, current.character(at: prefix) == previous.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < shared - prefix,
              current.character(at: current.length - 1 - suffix) == previous.character(at: previous.length - 1 - suffix) {
            suffix += 1
        }
        return NSRange(location: prefix, length: max(0, current.length - prefix - suffix))
    }

    /// Whether a change moved a line break, which is the one edit whose effect reaches past the
    /// paragraph it touched: splitting a line strands the tail of a URL in the paragraph after it.
    static func spansLineBreak(in current: NSString, previous: NSString, changed: NSRange) -> Bool {
        if changed.length > 0, current.substring(with: changed).contains("\n") { return true }
        let removed = max(0, previous.length - current.length + changed.length)
        guard removed > 0, changed.location < previous.length else { return false }
        let range = NSRange(location: changed.location, length: min(removed, previous.length - changed.location))
        return previous.substring(with: range).contains("\n")
    }
}

/// Remembers what was styled last so a keystroke re-attributes one line instead of the document.
struct MarkdownStylingTracker {
    private var styledText: String?
    private var styledFont: NSFont?

    /// The range to re-attribute; nil only for an empty document, where there is nothing to style.
    /// Calling this records the new state, so it must only be used when the caller really styles.
    mutating func rangeToRestyle(in text: NSString, font: NSFont, forcingFullPass: Bool) -> NSRange? {
        let fullRange = NSRange(location: 0, length: text.length)
        if fullRange.length == 0 {
            styledText = ""
            styledFont = font
            return nil
        }

        guard !forcingFullPass, styledFont == font, let previous = styledText else {
            styledText = text as String
            styledFont = font
            return fullRange
        }

        let changed = MarkdownStyling.changedRange(in: text, previous: previous as NSString)
        var target = text.paragraphRange(for: changed)
        if MarkdownStyling.spansLineBreak(in: text, previous: previous as NSString, changed: changed) {
            let after = NSRange(location: min(NSMaxRange(changed), text.length), length: 0)
            target = NSUnionRange(target, text.paragraphRange(for: after))
        }
        if target.length > MarkdownStyling.fullPassChangeThreshold {
            target = fullRange
        }
        styledText = text as String
        styledFont = font
        return target
    }
}
