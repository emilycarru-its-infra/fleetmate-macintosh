import SwiftUI

// MARK: - Shimmer Modifier

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0, phase - 0.15)),
                        .init(color: .secondary.opacity(0.2), location: phase),
                        .init(color: .clear, location: min(1, phase + 0.15)),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blendMode(.sourceAtop)
            )
            .onAppear {
                withAnimation(
                    .linear(duration: 3)
                    .repeatForever(autoreverses: false)
                ) {
                    phase = 2
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Base Skeleton Shape

struct SkeletonView: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.secondary.opacity(0.1))
            .frame(width: width, height: height)
            .shimmer()
    }
}

// MARK: - KPI Card Skeleton

struct SkeletonKPICard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonView(width: 80, height: 32, cornerRadius: 6)
            SkeletonView(width: 120, height: 12)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Chart Card Skeleton

struct SkeletonChartCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonView(width: 140, height: 16, cornerRadius: 4)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    let heights: [CGFloat] = [60, 90, 45, 80, 55, 70]
                    SkeletonView(height: heights[index], cornerRadius: 4)
                }
            }
            .frame(height: 100)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Table/List Row Skeleton

struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonView(width: 28, height: 28, cornerRadius: 6)
            SkeletonView(width: 140, height: 12)
            Spacer()
            SkeletonView(width: 80, height: 12)
            SkeletonView(width: 60, height: 12)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Previews

#Preview("Skeleton Components") {
    VStack(spacing: 20) {
        HStack(spacing: 12) {
            SkeletonKPICard()
            SkeletonKPICard()
            SkeletonKPICard()
        }

        SkeletonChartCard()

        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonRow()
                Divider()
            }
        }
    }
    .padding()
    .frame(width: 600)
}
