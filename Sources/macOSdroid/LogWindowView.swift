import SwiftUI

/// Dedicated activity-log window so diagnostics stay available without taking over the dashboard.
struct LogWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity Log")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))

                Text("Runtime events, install steps, launch attempts, and health checks are recorded here.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Log File") {
                model.revealActivityLogFile()
            }
            .buttonStyle(.bordered)
            .help("Reveal the persisted activity log in Finder.")

            Button("Clear Log") {
                model.clearLogs()
            }
            .buttonStyle(.bordered)
            .disabled(model.logs.isEmpty)
            .help("Clear both the in-memory activity history and the persisted activity log file.")
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if model.logs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("No activity yet")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Text("Start the runtime or import an APK to begin populating the activity stream.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.logs) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)

                            Text(entry.message)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}
