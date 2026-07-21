import SwiftUI

struct BTAdaptiveStack<Content: View>: View {
    let spacing: CGFloat
    let horizontalAlignment: VerticalAlignment
    let verticalAlignment: HorizontalAlignment
    let horizontalMinWidth: CGFloat
    let content: () -> Content

    init(
        spacing: CGFloat = BTSpacing.md,
        horizontalAlignment: VerticalAlignment = .center,
        verticalAlignment: HorizontalAlignment = .leading,
        horizontalMinWidth: CGFloat = 0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.spacing = spacing
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.horizontalMinWidth = horizontalMinWidth
        self.content = content
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: horizontalAlignment, spacing: spacing, content: content)
                .frame(minWidth: horizontalMinWidth, alignment: .leading)

            VStack(alignment: verticalAlignment, spacing: spacing, content: content)
        }
    }
}

struct BTTrailingActionRow<Leading: View, Trailing: View>: View {
    let spacing: CGFloat
    let horizontalAlignment: VerticalAlignment
    let horizontalMinWidth: CGFloat
    let leading: Leading
    let trailing: Trailing

    init(
        spacing: CGFloat = BTSpacing.md,
        horizontalAlignment: VerticalAlignment = .top,
        horizontalMinWidth: CGFloat = 0,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.spacing = spacing
        self.horizontalAlignment = horizontalAlignment
        self.horizontalMinWidth = horizontalMinWidth
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: horizontalAlignment, spacing: spacing) {
                leading
                Spacer(minLength: spacing)
                trailing
            }
            .frame(minWidth: horizontalMinWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: spacing) {
                leading
                trailing
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct BTFlowLayout: Layout {
    var spacing: CGFloat = BTSpacing.sm
    var rowSpacing: CGFloat = BTSpacing.sm

    init(spacing: CGFloat = BTSpacing.sm, rowSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.rowSpacing = rowSpacing ?? spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = arrangedRows(for: subviews, maxWidth: proposal.width ?? .greatestFiniteMagnitude)
        let width = rows.map(\.width).max() ?? 0
        let height = totalHeight(for: rows)
        return CGSize(
            width: proposal.width ?? width,
            height: height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangedRows(for: subviews, maxWidth: bounds.width)
        var currentY = bounds.minY

        for row in rows {
            var currentX = bounds.minX

            for element in row.elements {
                element.subview.place(
                    at: CGPoint(x: currentX, y: currentY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(element.size)
                )
                currentX += element.size.width + spacing
            }

            currentY += row.height + rowSpacing
        }
    }

    private func totalHeight(for rows: [Row]) -> CGFloat {
        guard let last = rows.last else { return 0 }
        let spacingHeight = CGFloat(max(0, rows.count - 1)) * rowSpacing
        return rows.dropLast().reduce(last.height + spacingHeight) { partial, row in
            partial + row.height
        }
    }

    private func arrangedRows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        let constrainedWidth = max(maxWidth, 1)
        var rows: [Row] = []
        var currentRow = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = currentRow.width == 0
                ? size.width
                : currentRow.width + spacing + size.width

            if currentRow.width > 0 && proposedWidth > constrainedWidth {
                rows.append(currentRow)
                currentRow = Row()
            }

            currentRow.add(subview: subview, size: size, spacing: spacing)
        }

        if !currentRow.elements.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private struct Row {
        var elements: [(subview: LayoutSubview, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func add(subview: LayoutSubview, size: CGSize, spacing: CGFloat) {
            if !elements.isEmpty {
                width += spacing
            }
            elements.append((subview, size))
            width += size.width
            height = max(height, size.height)
        }
    }
}
