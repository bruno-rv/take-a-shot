#if os(macOS)
import AppKit

/// Pure key-routing seam shared by both multiline text-input surfaces (Selection Overlay field
/// editor, post-capture editor `NSTextView`) — PLAN.md "Text Input" §Approach. Each surface's
/// AppKit delegate hook (`NSTextFieldDelegate.control(_:textView:doCommandBy:)` /
/// `NSTextViewDelegate.textView(_:doCommandBy:)`) translates its selector through this decision
/// before acting; the two surfaces then apply asymmetric insertion semantics on top of it (see
/// call sites) — that difference is deliberately NOT modeled here, only the routing itself.
enum TextInputKeyDecision: Equatable {
    case insertNewline
    case commit
    case pass

    static func action(for selector: Selector, commandModifier: Bool) -> TextInputKeyDecision {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            return commandModifier ? .commit : .insertNewline
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            return .commit
        }
        return .pass
    }
}

extension RGBAColor {
    /// No such conversion exists elsewhere — both text-input surfaces need the palette color as
    /// an `NSColor` while the person is typing (committed rendering already uses `cgColor` via
    /// `AnnotationRenderer`, untouched by this change).
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
#endif
