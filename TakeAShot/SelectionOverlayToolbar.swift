#if os(macOS)
import SwiftUI

/// The Selection Overlay's floating tool/palette bar (PLAN.md §8). Placed by
/// `SelectionToolbarPlacement.toolbarFrame` and hosted via `NSHostingView`, confined to exactly
/// that frame so it never steals mouse events meant for drawing/selection outside itself. New
/// view — does not modify `AnnotationEditor.swift`'s tool-creation logic or `MacToolbar`.
struct SelectionOverlayToolbarView: View {
    let activeTool: AnnotationTool
    let colorID: String
    let selectedEmoji: String
    let onSelectTool: (AnnotationTool) -> Void
    let onSelectColor: (AnnotationColorOption) -> Void
    let onSelectEmoji: (String) -> Void
    let onUndo: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(SelectionOverlayTools.ordered.enumerated()), id: \.element) { index, tool in
                    Button { onSelectTool(tool) } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .background(
                        activeTool == tool ? Color.accentColor.opacity(0.3) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .accessibilityLabel("\(tool.rawValue) (\(index + 1))")
                }

                Divider().frame(height: 18)

                ForEach(AnnotationPalette.options) { option in
                    Button { onSelectColor(option) } label: {
                        Circle()
                            .fill(option.displayColor)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().stroke(Color.primary, lineWidth: colorID == option.id ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.accessibilityLabel)
                }

                Divider().frame(height: 18)

                Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Undo")
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                Button(action: onConfirm) { Image(systemName: "checkmark").bold() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Confirm")
            }

            if activeTool == .emoji {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 4) {
                    ForEach(AnnotationPalette.emojiOptions, id: \.self) { emoji in
                        Button { onSelectEmoji(emoji) } label: {
                            Text(emoji)
                                .font(.title3)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(
                                    selectedEmoji == emoji
                                        ? Color.accentColor.opacity(0.35)
                                        : Color.white.opacity(0.06)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Emoji \(emoji)")
                        .accessibilityAddTraits(selectedEmoji == emoji ? .isSelected : [])
                    }
                }
                .frame(width: 216)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .fixedSize()
    }
}
#endif
