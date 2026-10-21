import SwiftUI

/// SwiftUI sidebar showing the document's heading hierarchy. Click on
/// a heading to jump the editor's cursor and scroll position there.
///
/// It sits on the system sidebar material, so its text uses the system
/// label colours, which follow Settings ▸ Appearance (the window chrome),
/// not the editor palette. The active row is tinted with the theme
/// accent (decision C4: accent in selection lists).
struct OutlineSidebar: View {
    let headings: [DocumentHeading]
    let activeHeadingID: Int?
    let accent: Color
    let onSelect: (DocumentHeading) -> Void

    /// Leading text inset of a row: 10, 24, 38 … for H1, H2, H3 (board
    /// `Main`). It comes on top of the row's own 10 pt margin.
    static func indent(forLevel level: Int) -> CGFloat {
        10 + CGFloat(max(level, 1) - 1) * 14
    }

    /// Opacity of the accent behind the active row: enough to read as
    /// "selected" without competing with the editor's caret and links.
    static let activeRowOpacity: Double = 0.16

    var body: some View {
        if headings.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(headings) { h in
                        row(for: h)
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Outline")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No headings yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Type # then a space to add one.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(for h: DocumentHeading) -> some View {
        let isActive = h.id == activeHeadingID
        return Button {
            onSelect(h)
        } label: {
            Text(h.text)
                .font(.system(size: 13, weight: (isActive || h.level == 1) ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, Self.indent(forLevel: h.level))
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? accent.opacity(Self.activeRowOpacity) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The rows are buttons, not list selection (the system highlight
        // would paint over the accent tint), so VoiceOver learns which
        // heading holds the caret from the trait instead.
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityLabel("Heading \(h.level), \(h.text)")
    }
}
