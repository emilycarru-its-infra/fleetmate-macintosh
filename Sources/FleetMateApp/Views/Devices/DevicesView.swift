import SwiftUI
import FleetMateCore

/// The Devices tab's platform views. Mac is the Apple organization's device
/// lifecycle cross-referenced with Intune; Windows is the Intune view, which
/// becomes Autopilot-led in #120.
enum DevicePlatformView: String, CaseIterable {
    case mac = "Mac"
    case windows = "Windows"
}

struct DevicesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        DevicesPlatformSwitch(store: appState.appleOrg)
    }
}

/// Split out so it can observe the Apple organization store: the Mac view
/// appears as soon as a profile is added in Settings.
private struct DevicesPlatformSwitch: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: AppleOrgStore
    @AppStorage("devices.platform") private var platform: DevicePlatformView = .mac

    var body: some View {
        if store.hasProfile {
            Group {
                switch platform {
                case .mac: AppleOrgDevicesView(store: store)
                case .windows: IntuneDevicesView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    SegmentedPill(
                        selection: $platform,
                        options: DevicePlatformView.allCases,
                        label: { $0.rawValue },
                        segmentWidth: 72
                    )
                }
            }
        } else {
            // No Apple organization profile: the Intune view alone, as before.
            IntuneDevicesView()
        }
    }
}
