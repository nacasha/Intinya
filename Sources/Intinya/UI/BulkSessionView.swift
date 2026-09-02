import SwiftUI

/// Shown when several recordings are selected.
///
/// Selecting more than one has to lead somewhere — otherwise multi-select is
/// only good for deleting, and the bulk operation people actually want most is
/// filing a backlog of recordings under the right type.
struct BulkSessionView: View {
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    let sessions: [Session]
    let onDelete: () -> Void
    let onAssignType: (MeetingType?) -> Void
    let onClear: () -> Void

    private var totalDuration: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    private var transcribed: Int {
        sessions.filter(\.hasTranscript).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sessions) { session in
                        HStack(spacing: 9) {
                            Image(systemName: meetingTypes.type(id: session.typeID)?.systemImage
                                  ?? (session.hasTranscript ? "text.bubble" : "waveform"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 15)
                            Text(session.displayTitle)
                                .font(Theme.Font.body)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(session.subtitle)
                                .font(Theme.Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.content)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sessions.count) recordings selected")
                        .font(Theme.Font.display)
                    Text("\(totalDuration.clockString) total · \(transcribed) transcribed")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                HeaderMenu(
                    title: "Set Template",
                    systemImage: "square.grid.2x2",
                    tint: Theme.system,
                    help: "Assign a template to all of these at once",
                    items: meetingTypes.types.map { type in
                        .action(type.name, systemImage: type.systemImage) { onAssignType(type) }
                    } + [
                        .separator,
                        .action("No Type", systemImage: "slash.circle") { onAssignType(nil) },
                    ]
                )

                HeaderAction(
                    title: "Delete",
                    systemImage: "trash",
                    tint: Theme.recording,
                    help: "Delete all selected recordings"
                ) { onDelete() }

                Spacer()

                HeaderAction(
                    title: "Clear Selection",
                    systemImage: "xmark",
                    help: "Deselect everything"
                ) { onClear() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }
}
