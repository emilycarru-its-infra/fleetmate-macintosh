import SwiftUI

/// Settings ▸ Appearance — the app's text size control.
///
/// macOS has no Dynamic Type for an app to inherit, so FleetMate carries its own
/// scale. The preview below re-renders live at the chosen scale.
struct AppearanceSettingsView: View {
    @AppStorage(AppFontScale.storageKey) private var fontScale: Double = AppFontScale.default

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                textSizeSection
                previewSection
            }
            .padding(20)
        }
    }

    // MARK: Text size

    private var textSizeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Text size").appFont(.headline)
                    Spacer()
                    Text(AppFontScale.label(fontScale))
                        .appFont(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Reset") { fontScale = AppFontScale.default }
                        .appFont(.caption)
                        .disabled(abs(fontScale - AppFontScale.default) < 0.001)
                }

                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $fontScale,
                        in: AppFontScale.range,
                        step: AppFontScale.step
                    )
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary)
                }

                Text("Scales every text style in FleetMate. macOS has no system-wide Dynamic Type setting for apps to follow, so this is FleetMate's own control.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    // MARK: Live preview

    private var previewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview").appFont(.headline)
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Add display reconciliation blueprint")
                        .appFont(.body, weight: .semibold)
                    Text("Rod Christiansen request !10716 into Devices/ReportMate")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ForEach(AppTextStyle.allCases, id: \.self) { style in
                    HStack(alignment: .firstTextBaseline) {
                        Text(style.rawValue)
                            .appFont(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 90, alignment: .leading)
                        Text("The quick brown fox")
                            .appFont(style)
                        Spacer()
                        Text("\((style.basePointSize * CGFloat(fontScale)).rounded(), specifier: "%.0f") pt")
                            .appFont(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(4)
        }
    }
}
