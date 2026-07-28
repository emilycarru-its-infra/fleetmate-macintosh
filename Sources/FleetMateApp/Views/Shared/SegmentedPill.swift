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
        .background(.secondary.opacity(0.08), in: Capsule())
    }
}
