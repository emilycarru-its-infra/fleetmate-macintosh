import SwiftUI
import FleetMateCore

/// Settings ▸ Appearance — theme, text size and the Dock icon's badge.
///
/// macOS has no Dynamic Type for an app to inherit, so FleetMate carries its own
/// scale. The preview below re-renders live at the chosen scale.
struct AppearanceSettingsView: View {
    @AppStorage(AppFontScale.storageKey) private var fontScale: Double = AppFontScale.default
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system
    @AppStorage(InboxBadge.dockSettingKey) private var showDockBadge: Bool = InboxBadge.dockSettingDefault
    /// False when System Settings ▸ Notifications has badges off for this app.
    @State private var systemAllowsBadges = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                themeSection
                textSizeSection
                dockSection
                previewSection
            }
            .padding(20)
        }
    }

    // MARK: Theme

    private var themeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Theme").appFont(.headline)
                    Spacer()
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Light or Dark keeps \(AppEdition.current.displayName) in that appearance whatever macOS is set to.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
        .onChange(of: theme) { _, newTheme in newTheme.apply() }
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

                Text("Scales every text style in \(AppEdition.current.displayName). macOS has no system-wide Dynamic Type setting for apps to follow, so this is \(AppEdition.current.displayName)'s own control.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    // MARK: Dock

    private var dockSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $showDockBadge) {
                    Text("Show unread count on Dock icon").appFont(.headline)
                }
                .toggleStyle(.switch)

                Text("Badges \(AppEdition.current.displayName)'s Dock icon with the number of unread comments in the Tickets inbox, the way Mail shows unread mail.")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if showDockBadge && !systemAllowsBadges {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Badges are turned off for \(AppEdition.current.displayName) in System Settings, so the Dock icon won't show the count.",
                              systemImage: "exclamationmark.triangle")
                            .appFont(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Notifications Settings…") {
                            if let url = DockBadgeSystemSetting.settingsURL { openURL(url) }
                        }
                        .appFont(.caption)
                    }
                }
            }
            .padding(4)
        }
        .task { systemAllowsBadges = await DockBadgeSystemSetting.badgesAllowed() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { systemAllowsBadges = await DockBadgeSystemSetting.badgesAllowed() }
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
                    Text("Ada Lovelace request !4821 into Platform/Inventory")
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
