import SwiftUI

/// Wrapping row of word tokens; each word reports hover and can be highlighted.
struct WordFlowText: View {
    let tokens: [String]
    let font: Font
    let color: Color
    let hovered: Int?
    let highlighted: Set<Int>
    let onHover: (Int?) -> Void

    var body: some View {
        WordFlowLayout(horizontalSpacing: 4, verticalSpacing: 2) {
            ForEach(tokens.indices, id: \.self) { index in
                Text(tokens[index])
                    .font(font)
                    .foregroundStyle(color)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(background(for: index))
                    )
                    .onHover { inside in
                        if inside {
                            onHover(index)
                        } else if hovered == index {
                            onHover(nil)
                        }
                    }
            }
        }
    }

    private func background(for index: Int) -> Color {
        if hovered == index {
            return Color.accentColor.opacity(0.35)
        }
        if highlighted.contains(index) {
            return Color.yellow.opacity(0.45)
        }
        return .clear
    }
}

struct WordFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * verticalSpacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = current.indices.isEmpty ? size.width : horizontalSpacing + size.width
            if !current.indices.isEmpty, current.width + extra > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.indices.append(index)
            current.width += current.indices.count == 1 ? size.width : horizontalSpacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
