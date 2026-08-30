import SwiftUI

/// Every recording, as browsable cards.
///
/// The sidebar list is built for switching between recordings while working on
/// one. This is for the other task — looking over everything at once — which a
/// 200pt column cannot do. Cards have room for a preview, so a recording is
/// identifiable even before an AI title exists.
struct LibraryView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @EnvironmentObject private var activity: ActivityCenter

    let onOpen: (Session) -> Void

    @State private var search = ""
    @AppStorage("library.sort") private var sortRaw = Sort.newest.rawValue
    @AppStorage("library.hideEmpty") private var hideEmpty = true
    @AppStorage("library.filterTypeID") private var filterTypeID = ""
    @AppStorage("library.viewMode") private var viewModeRaw = ViewMode.grid.rawValue
    @AppStorage("library.groupByDay") private var groupByDay = true

    enum ViewMode: String { case grid, list }
    private var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .grid }

    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, longest, title
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: return "Newest"
            case .oldest: return "Oldest"
            case .longest: return "Longest"
            case .title: return "Title"
            }
        }
    }

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .newest }

    private var visible: [Session] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = sessions.sessions.filter { session in
            if hideEmpty, session.isEmpty { return false }
            if !filterTypeID.isEmpty, session.typeID?.uuidString != filterTypeID { return false }
            guard !needle.isEmpty else { return true }
            return session.searchText.contains(needle)
                || session.displayTitle.lowercased().contains(needle)
        }

        switch sort {
        case .newest: return filtered.sorted { $0.recordedAt > $1.recordedAt }
        case .oldest: return filtered.sorted { $0.recordedAt < $1.recordedAt }
        case .longest: return filtered.sorted { $0.duration > $1.duration }
        case .title: return filtered.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
        }
    }

    private var summaryLine: String {
        var line = "\(visible.count) shown · \(totalDuration.clockString) total"
        if activity.busyCount > 0 { line += " · \(activity.busyCount) running" }
        return line
    }

    private var totalDuration: TimeInterval {
        visible.reduce(0) { $0 + $1.duration }
    }

    /// One group when ungrouped, one per day otherwise. The chosen sort still
    /// applies *within* each day, so grouping and sorting compose rather than
    /// one overriding the other.
    private var groups: [(day: Date?, sessions: [Session])] {
        guard groupByDay else { return [(day: nil, sessions: visible)] }
        return Dictionary(grouping: visible, by: \.day)
            .map { (day: Optional($0.key), sessions: $0.value) }
            .sorted { ($0.day ?? .distantPast) > ($1.day ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if visible.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.day) { group in
                            Section {
                                content(for: group.sessions)
                            } header: {
                                if let day = group.day {
                                    Text(Session.dayLabel(for: day))
                                        .font(Theme.Font.label)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.regularMaterial)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("All Recordings")
                        .font(Theme.Font.display)
                    Text(summaryLine)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("Search titles, transcripts, and notes", text: $search)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.caption)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .frame(maxWidth: 320)

                HeaderActionMenu(
                    title: filterName,
                    systemImage: "line.3.horizontal.decrease",
                    tint: filterTypeID.isEmpty ? nil : Theme.system,
                    help: "Show only one meeting type"
                ) {
                    Button("All Types") { filterTypeID = "" }
                    Divider()
                    ForEach(meetingTypes.types) { type in
                        Button {
                            filterTypeID = type.id.uuidString
                        } label: {
                            Label(type.name, systemImage: type.systemImage)
                        }
                    }
                }

                HeaderActionMenu(
                    title: sort.label,
                    systemImage: "arrow.up.arrow.down",
                    help: "Sort order"
                ) {
                    ForEach(Sort.allCases) { option in
                        Button(option.label) { sortRaw = option.rawValue }
                    }
                }

                HeaderAction(
                    title: hideEmpty ? "Hiding Empty" : "Showing All",
                    systemImage: hideEmpty ? "eye.slash" : "eye",
                    help: "Recordings that captured nothing at all"
                ) { hideEmpty.toggle() }

                HeaderAction(
                    title: groupByDay ? "By Day" : "Flat",
                    systemImage: groupByDay ? "calendar" : "list.bullet.indent",
                    tint: groupByDay ? Theme.system : nil,
                    help: groupByDay ? "Grouped by day" : "One continuous list"
                ) { groupByDay.toggle() }

                HeaderAction(
                    title: viewMode == .grid ? "Grid" : "List",
                    systemImage: viewMode == .grid ? "square.grid.2x2" : "list.bullet",
                    help: viewMode == .grid ? "Switch to a compact list" : "Switch to cards"
                ) {
                    viewModeRaw = viewMode == .grid ? ViewMode.list.rawValue : ViewMode.grid.rawValue
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func content(for group: [Session]) -> some View {
        switch viewMode {
        case .grid:
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 14)],
                spacing: 14
            ) {
                ForEach(group) { session in
                    SessionCard(
                        session: session,
                        type: meetingTypes.type(id: session.typeID),
                        busyLabel: activity.label(for: session.id),
                        progress: activity.progress(for: session.id)
                    ) { onOpen(session) }
                }
            }
            .padding(.horizontal, 20)

        case .list:
            LazyVStack(spacing: 2) {
                ForEach(group) { session in
                    SessionListRow(
                        session: session,
                        type: meetingTypes.type(id: session.typeID),
                        busyLabel: activity.label(for: session.id)
                    ) { onOpen(session) }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var filterName: String {
        guard !filterTypeID.isEmpty,
              let id = UUID(uuidString: filterTypeID),
              let type = meetingTypes.type(id: id)
        else { return "All Types" }
        return type.name
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(sessions.sessions.isEmpty ? "Nothing recorded yet" : "No recordings match")
                .font(Theme.Font.title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionCard: View {
    let session: Session
    let type: MeetingType?
    var busyLabel: String?
    var progress: Double?
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: type?.systemImage ?? "waveform")
                        .font(.system(size: 10, weight: .semibold))
                    Text((type?.name ?? "No Type").uppercased())
                        .font(Theme.Font.label)
                        .tracking(0.5)
                    Spacer(minLength: 0)
                    ForEach(session.markers, id: \.self) { marker in
                        Image(systemName: marker)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(type == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.system))

                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                // Running work is shown where the recording is, so it is visible
                // without opening it.
                if let busyLabel {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                        Text(busyLabel)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.system)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let progress {
                            Text("\(Int(progress * 100))%")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.system)
                                .monospacedDigit()
                        }
                    }
                    .padding(.bottom, 2)
                }

                HStack(spacing: 6) {
                    Text(session.fullTitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(session.subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(height: 168, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(hovering ? 0.16 : 0.08), lineWidth: 1)
            }
            .scaleEffect(hovering ? 1.012 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.16), value: hovering)
    }
}


/// The compact alternative to a card: one line per recording, so many more fit
/// on screen when you are scanning rather than browsing.
private struct SessionListRow: View {
    let session: Session
    let type: MeetingType?
    var busyLabel: String?
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: type?.systemImage ?? "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(type == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.system))
                    .frame(width: 16)

                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(minWidth: 140, alignment: .leading)
                    .layoutPriority(1)

                Text(session.preview)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if busyLabel != nil {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }

                ForEach(session.markers, id: \.self) { marker in
                    Image(systemName: marker)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                Text(session.subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 118, alignment: .trailing)

                Text(Session.timeFormatter.string(from: session.recordedAt))
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0.025))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.14), value: hovering)
    }
}
