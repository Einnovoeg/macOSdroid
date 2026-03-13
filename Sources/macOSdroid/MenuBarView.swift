import AppKit
import SwiftUI

/// Compact control surface shown from the menu bar when the dashboard is hidden.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOSdroid")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))

                    Text(model.statusMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(model.runtimeState.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(statusColor)
            }

            if let device = model.connectedDevice {
                Label(device, systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button(model.canStart ? "Start Runtime" : "Runtime Starting") {
                model.startRuntime()
            }
            .disabled(!model.canStart)

            Button(model.canStop ? "Stop Runtime" : "Runtime Stopped") {
                model.stopRuntime()
            }
            .disabled(!model.canStop)

            Button("Import APKs") {
                model.importAPKFiles()
            }

            Button("Open Watch Folder") {
                model.revealWatchFolder()
            }

            Button("Rescan Library") {
                model.refreshLibrary()
            }

            Button("Hide Dashboard") {
                model.hideDashboard()
            }
            .disabled(!model.settings.menuBarOnly)

            Divider()

            Link(destination: ProjectLinks.support) {
                Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var statusColor: Color {
        switch model.runtimeState {
        case .stopped:
            .gray
        case .starting, .stopping:
            Color(red: 0.93, green: 0.78, blue: 0.43)
        case .running:
            Color(red: 0.29, green: 0.77, blue: 0.66)
        case .failed:
            Color(red: 0.87, green: 0.34, blue: 0.34)
        }
    }
}
