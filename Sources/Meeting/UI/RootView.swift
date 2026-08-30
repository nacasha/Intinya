import SwiftUI

/// Which pane the detail area is showing.
enum Route: Hashable {
    case record
    case glossary
    case meetingTypes
    case library
    case settings
    case session(String)   // session id
    case multiple          // more than one recording selected
}

/// Sidebar of past recordings alongside the live recording pane.
struct RootView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var glossary: GlossaryStore
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @EnvironmentObject private var activity: ActivityCenter
    @State private var route: Route? = .record
    /// Session ids selected in the list.
    ///
    /// Separate from `route`: the list holds only recordings, while `route` also
    /// covers the pinned destinations. One selected recording navigates to it;
    /// several switch the detail pane to bulk actions.
    @State private var selection = Set<String>()
    /// Recordings awaiting delete confirmation.
    @State private var pendingDelete: [Session] = []
    @State private var search = ""
    @AppStorage("sidebar.hideEmpty") private var hideEmpty = true
    @AppStorage("sidebar.filterTypeID") private var filterTypeID = ""

    /// Recordings after search and filters, newest first.
    private var visibleSessions: [Session] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.sessions.filter { session in
            if hideEmpty, session.isEmpty { return false }
            if !filterTypeID.isEmpty, session.typeID?.uuidString != filterTypeID { return false }
            guard !needle.isEmpty else { return true }
            return session.searchText.contains(needle)
                || session.displayTitle.lowercased().contains(needle)
        }
    }

    /// Grouped by day. A list where every row starts with a date is unscannable
    /// once a single day holds ten recordings.
    private var grouped: [(day: Date, sessions: [Session])] {
        Dictionary(grouping: visibleSessions, by: \.day)
            .map { (day: $0.key, sessions: $0.value.sorted { $0.recordedAt > $1.recordedAt }) }
            .sorted { $0.day > $1.day }
    }

    private var hiddenCount: Int {
        sessions.sessions.count - visibleSessions.count
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 520, ideal: 700)
        }
        .frame(minWidth: 860, minHeight: 560)
        // Any write to a transcript invalidates the library's snapshot — which
        // is what left the AI menu disabled after a stop, since it was reading
        // metadata captured before the last chunks had been saved.
        .onChange(of: recorder.transcriptRevision) { _, _ in sessions.refresh() }
        // Once the queue has drained the session is complete on disk, so open it
        // and give the record screen back empty for the next meeting.
        .onChange(of: recorder.completedSessionID) { _, id in
            guard let id else { return }
            sessions.refresh()
            route = .session(id)
            recorder.resetForNextRecording()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Pinned: the destinations stay reachable however far down the
            // recordings you have scrolled.
            VStack(spacing: 2) {
                SidebarNavRow(
                    title: "Record",
                    systemImage: recorder.isRecording ? "record.circle.fill" : "mic.circle",
                    tint: recorder.isRecording ? Theme.recording : nil,
                    indicator: recorder.isRecording ? Theme.recording : nil,
                    isSelected: route == .record
                ) { route = .record; selection.removeAll() }

                SidebarNavRow(
                    title: "All Recordings",
                    systemImage: "square.grid.2x2.fill",
                    badge: "\(sessions.sessions.count)",
                    isSelected: route == .library
                ) { route = .library; selection.removeAll() }

                SidebarNavRow(
                    title: "Glossary",
                    systemImage: "character.book.closed",
                    badge: glossary.learned.isEmpty ? nil : "\(glossary.learned.count)",
                    isSelected: route == .glossary
                ) { route = .glossary; selection.removeAll() }

                SidebarNavRow(
                    title: "Settings",
                    systemImage: "gearshape",
                    isSelected: route == .settings
                ) { route = .settings; selection.removeAll() }

                SidebarNavRow(
                    title: "Meeting Types",
                    systemImage: "rectangle.3.group",
                    badge: "\(meetingTypes.types.count)",
                    isSelected: route == .meetingTypes
                ) { route = .meetingTypes; selection.removeAll() }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider().opacity(0.5)

            searchBar

            List(selection: $selection) {
                if grouped.isEmpty {
                    Text(sessions.sessions.isEmpty
                         ? "Nothing recorded yet"
                         : "No recordings match")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(grouped, id: \.day) { group in
                        Section(Session.dayLabel(for: group.day)) {
                            ForEach(group.sessions) { session in
                                SessionRow(
                                    session: session,
                                    type: meetingTypes.type(id: session.typeID),
                                    isBusy: activity.isBusy(session.id),
                                    busyLabel: activity.label(for: session.id)
                                )
                                .tag(session.id)
                                .contextMenu {
                                    Button("Reveal in Finder") { sessions.reveal(session) }
                                    Button("Copy Transcript") { copy(session) }
                                        .disabled(!session.hasTranscript)
                                    Divider()
                                    Button("Delete…", role: .destructive) {
                                        pendingDelete = [session]
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                if let error = sessions.lastError {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.recording)
                        .padding(10)
                }
            }
        }
        .background(.regularMaterial)
        .onChange(of: selection) { _, ids in
            switch ids.count {
            case 0: break                       // keep whatever was open
            case 1:
                if let id = ids.first { route = .session(id) }
            default:
                route = .multiple
            }
        }
        // Destructive and irreversible: this removes the audio too, which is the
        // one thing that cannot be regenerated.
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { !pendingDelete.isEmpty },
                set: { if !$0 { pendingDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text("The audio, transcript, notes, and screen capture are removed. This cannot be undone.")
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? "Delete \u{201C}\(pendingDelete[0].displayTitle)\u{201D}?"
            : "Delete \(pendingDelete.count) recordings?"
    }

    private func confirmDelete() {
        let ids = Set(pendingDelete.map(\.id))
        if case .session(let open) = route, ids.contains(open) { route = .record }
        if route == .multiple { route = .record }
        pendingDelete.forEach { activity.forget($0.id); sessions.delete($0) }
        selection.subtract(ids)
        pendingDelete = []
    }

    private var searchBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Search recordings", text: $search)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.caption)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            }

            HStack(spacing: 6) {
                Menu {
                    Button("All Types") { filterTypeID = "" }
                    Divider()
                    ForEach(meetingTypes.types) { type in
                        Button {
                            filterTypeID = type.id.uuidString
                        } label: {
                            Label(type.name, systemImage: type.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 8, weight: .bold))
                        Text(filterName.uppercased())
                            .font(Theme.Font.label)
                            .lineLimit(1)
                    }
                    .foregroundStyle(filterTypeID.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.system))
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()

                Spacer()

                // Roughly half of a real library is false starts; hiding them by
                // default is the difference between browsing and wading.
                Button {
                    hideEmpty.toggle()
                } label: {
                    Text(hideEmpty ? "HIDING \(hiddenCount) EMPTY" : "SHOWING ALL")
                        .font(Theme.Font.label)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(hideEmpty
                      ? "Recordings with no transcript, notes, sections, or screen capture are hidden. Their audio is still on disk."
                      : "Showing every recording, including ones that produced nothing")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var filterName: String {
        guard !filterTypeID.isEmpty,
              let id = UUID(uuidString: filterTypeID),
              let type = meetingTypes.type(id: id)
        else { return "All Types" }
        return type.name
    }

    @ViewBuilder
    private var detail: some View {
        switch route {
        case .multiple:
            BulkSessionView(
                sessions: selectedSessions,
                onDelete: { pendingDelete = selectedSessions },
                onAssignType: { assignType($0) },
                onClear: { selection.removeAll(); route = .record }
            )
        case .library:
            LibraryView { session in
                selection = [session.id]
                route = .session(session.id)
            }
        case .settings:
            SettingsView()
        case .glossary:
            GlossaryView()
        case .meetingTypes:
            MeetingTypesView()
        case .session(let id):
            if let session = sessions.sessions.first(where: { $0.id == id }) {
                SessionDetailView(
                    session: session,
                    ai: activity.ai(for: session.id),
                    enhancer: activity.enhancer(for: session.id)
                )
                .id(session.id)
            } else {
                // The selected recording was deleted underneath us.
                ContentView()
            }
        default:
            ContentView()
        }
    }

    private var selectedSessions: [Session] {
        sessions.sessions.filter { selection.contains($0.id) }
    }

    private func assignType(_ type: MeetingType?) {
        for session in selectedSessions {
            SessionStore.setType(type?.id, in: session.directory)
        }
        if let type { meetingTypes.noteUsed(type) }
        sessions.refresh()
    }

    private func copy(_ session: Session) {
        let text = sessions.exportText(session)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

}

private struct SessionRow: View {
    let session: Session
    var type: MeetingType?
    var isBusy: Bool = false
    var busyLabel: String?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: type?.systemImage ?? (session.hasTranscript ? "text.bubble" : "waveform"))
                .font(.system(size: 11))
                .foregroundStyle(type == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.system))
                // Same column as the navigation rows above, so the whole sidebar
                // reads as one aligned list rather than two.
                .frame(width: SidebarItem.iconWidth, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(session.subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    // Icons rather than more words: four facts in one grey line
                    // stopped being readable.
                    ForEach(session.markers, id: \.self) { marker in
                        Image(systemName: marker)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.vertical, 2)
        .help(busyLabel ?? "")
    }
}
