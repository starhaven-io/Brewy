import AppKit
import SwiftUI

// MARK: - Shared Visual Primitives

extension Color {
    static var brewyAccent: Color { .orange }
}

extension FocusedValues {
    @Entry var columnSearchFocus: Binding<Bool>?
}

struct ColumnSearchBar<Accessory: View>: View {
    @Binding private var text: String
    // periphery:ignore - Read through NSViewRepresentable and focused-scene projected bindings.
    @State private var isSearchFocused = false
    private let prompt: String
    private let accessibilityIdentifier: String
    private let accessory: Accessory

    init(
        text: Binding<String>,
        prompt: String,
        accessibilityIdentifier: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        _text = text
        self.prompt = prompt
        self.accessibilityIdentifier = accessibilityIdentifier
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: $text,
                isFocused: $isSearchFocused,
                prompt: prompt,
                accessibilityIdentifier: accessibilityIdentifier
            )
            accessory
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .focusedSceneValue(\.columnSearchFocus, $isSearchFocused)
    }
}

extension ColumnSearchBar where Accessory == EmptyView {
    init(text: Binding<String>, prompt: String, accessibilityIdentifier: String) {
        self.init(text: text, prompt: prompt, accessibilityIdentifier: accessibilityIdentifier) {
            EmptyView()
        }
    }
}

private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let prompt: String
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.delegate = context.coordinator
        searchField.placeholderString = prompt
        searchField.identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        searchField.placeholderString = prompt

        if searchField.stringValue != text {
            searchField.stringValue = text
        }

        guard isFocused, searchField.currentEditor() == nil else { return }
        DispatchQueue.main.async {
            isFocused = false
            searchField.window?.makeFirstResponder(searchField)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let searchField = control as? NSSearchField else { return false }

            guard !searchField.stringValue.isEmpty else { return false }
            searchField.stringValue = ""
            text.wrappedValue = ""
            return true
        }
    }
}

extension PackageSource {
    var brewyDisplayName: String {
        switch self {
        case .formula: "Formula"
        case .cask: "Cask"
        case .mas: "Mac App Store"
        }
    }

    var brewyShortName: String {
        switch self {
        case .formula: "formula"
        case .cask: "cask"
        case .mas: "mas"
        }
    }

    var brewySymbolName: String {
        switch self {
        case .formula: "terminal.fill"
        case .cask: "macwindow"
        case .mas: "app.badge.fill"
        }
    }

    var brewyTint: Color {
        switch self {
        case .formula: .green
        case .cask: .indigo
        case .mas: .pink
        }
    }
}

enum PackageSourceBadgeStyle {
    case short
    case full
}

struct PackageSourceBadge: View {
    let source: PackageSource
    var style: PackageSourceBadgeStyle = .short

    private var text: String {
        switch style {
        case .short: source.brewyShortName
        case .full: source.brewyDisplayName
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(source.brewyTint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(source.brewyTint.opacity(0.12), in: .capsule)
            .accessibilityLabel(source.brewyDisplayName)
    }
}

struct PackageSourceIcon: View {
    let source: PackageSource
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(size * 0.28, 8), style: .continuous)
                .fill(source.brewyTint.opacity(0.12))
            Image(systemName: source.brewySymbolName)
                .font(.system(size: max(size * 0.48, 12), weight: .semibold))
                .foregroundStyle(source.brewyTint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BrewyStatusBadge: View {
    let title: String
    let systemImage: String?
    let color: Color

    init(_ title: String, systemImage: String? = nil, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(title)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.12), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

struct BrewyCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

struct BrewyStatusDot: View {
    let color: Color
    let label: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(label)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    struct CacheData {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout CacheData, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        let rows = computeRows(proposal: proposal, sizes: cache.sizes)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = row.map(\.height).max() ?? 0
            height += rowHeight
            if index < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        let rows = computeRows(proposal: proposal, sizes: cache.sizes)
        var y = bounds.minY
        var subviewIndex = 0
        for row in rows {
            let rowHeight = row.map(\.height).max() ?? 0
            var x = bounds.minX
            for size in row {
                subviews[subviewIndex].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                subviewIndex += 1
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, sizes: [CGSize]) -> [[CGSize]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var currentWidth: CGFloat = 0
        for size in sizes {
            if currentWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(size)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

// MARK: - Console Output

struct ConsoleOutput: View {
    let text: String
    var maxHeight: CGFloat?
    var padding: CGFloat = 12

    var body: some View {
        let content = Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        if let maxHeight {
            ScrollView { content }.frame(maxHeight: maxHeight)
        } else {
            content
        }
    }
}

// MARK: - Action Overlay

struct ActionOverlay: View {
    let output: String
    let canCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(canCancel ? "Running..." : "Finishing...")
                .font(.headline)
            if !output.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear
                            .frame(height: 1)
                            .id("actionOverlayBottom")
                    }
                    .frame(maxHeight: 200)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                    .onChange(of: output, initial: true) {
                        proxy.scrollTo("actionOverlayBottom", anchor: .bottom)
                    }
                }
            }
            if canCancel {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 400)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(radius: 20, y: 10)
    }
}
