import Foundation

/// Markdown checklist items: where a line's box is, and what the line becomes when it is toggled.
/// Kept apart from the text view so it can be checked without a running app.
enum Checklist {
    private static let unchecked = "- [ ] "
    private static let checked = "- [x] "
    private static let markerLength = 6

    /// Leading indentation. Only spaces and tabs count, so its length is the same in characters and
    /// in the UTF-16 units the text view measures with.
    private static func indentLength(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func isChecked(_ body: Substring) -> Bool {
        body.hasPrefix(checked) || body.hasPrefix("- [X] ")
    }

    /// The UTF-16 range of the box — `[ ]` or `[x]` — inside `line`, when the line is a checklist item.
    /// Only a click on the box toggles it; the space before the item text stays a caret position.
    static func boxRange(in line: String) -> NSRange? {
        let indent = indentLength(of: line)
        let body = line.dropFirst(indent)
        guard body.hasPrefix(unchecked) || isChecked(body) else { return nil }
        return NSRange(location: indent + 2, length: 3)
    }

    /// The line with its item toggled: checked and unchecked swap; a bullet or plain text becomes an
    /// unchecked item. Indentation, the rest of the line and its line ending are kept as they are.
    static func toggled(_ line: String) -> String {
        let indent = String(line.prefix(indentLength(of: line)))
        let body = line.dropFirst(indent.count)
        if body.hasPrefix(unchecked) {
            return indent + checked + String(body.dropFirst(markerLength))
        }
        if isChecked(body) {
            return indent + unchecked + String(body.dropFirst(markerLength))
        }
        for bullet in ["- ", "* ", "+ "] where body.hasPrefix(bullet) {
            return indent + unchecked + String(body.dropFirst(bullet.count))
        }
        return indent + unchecked + String(body)
    }
}
