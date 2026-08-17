import SwiftUI

/// The capsule segmented control used for view-mode switching.
///
/// Extracted from TicketsView so Projects can use the same control rather than
/// growing a second, slightly-different copy. Generic over the selection type;
/// callers supply the options and how to label them.
struct SegmentedPill<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var segmentWidth: CGFloat = 56

    @Namespace private var pillNS

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Text(label(option))
                    .appFont(fixed: 12, weight: selection == option ? .semibold : .regular)
                    .foregroundStyle(selection == option ? .primary : .secondary)
                    .frame(width: segmentWidth, height: 24)
                    .background {
                        if selection == option {
                            Capsule()
                                .fill(.primary.opacity(0.15))
                                .matchedGeometryEffect(id: "pill", in: pillNS)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.2)) {
                            selection = option
                        }
                    }
            }
        }
        .padding(3)
        .modifier(PillEnclosure())
    }
}

/// The pill's enclosing capsule — only where the system doesn't already draw
/// one. macOS 26 wraps every toolbar item in its own liquid-glass capsule, so
/// drawing our own inside it stacked three nested capsules (glass → gray →
/// selection) where the design wants two.
private struct PillEnclosure: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(.secondary.opacity(0.08), in: Capsule())
        }
    }
}

/// Toolbar-safe dropdown. The macOS 26 glass toolbar renders Menu and Picker
/// labels icon-only (an empty pill with a chevron), so this is a plain text
/// pill — same construction as SegmentedPill — that presents its options in
/// a popover.
struct PillMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 5) {
            Text(label(selection))
                .appFont(fixed: 12)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .appFont(fixed: 9, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Capsule().fill(.primary.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { isPresented.toggle() }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        isPresented = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .appFont(fixed: 10, weight: .semibold)
                                .opacity(selection == option ? 1 : 0)
                            Text(label(option))
                                .appFont(fixed: 12)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 170, alignment: .leading)
        }
    }
}
