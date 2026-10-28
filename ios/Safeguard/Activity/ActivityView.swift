import SwiftUI

struct ActivityView: View {
    @StateObject private var model = ProtectViewModel.shared
    @State private var showingDeleteAll = false

    var body: some View {
        NavigationStack {
            Group {
                if model.history.entries.isEmpty {
                    ContentUnavailableView {
                        Label("Activity", systemImage: "list.bullet.clipboard")
                            .foregroundStyle(DS.Colors.accent)
                    } description: {
                        Text("No SOS events yet. Finished SOS calls appear here.")
                    }
                } else {
                    List(model.history.entries, id: \.id) { entry in
                        NavigationLink {
                            ActivityDetailView(entry: entry)
                        } label: {
                            ActivityRow(entry: entry)
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                if !model.history.entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Delete all", role: .destructive) {
                            showingDeleteAll = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete all events?",
                isPresented: $showingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Delete all", role: .destructive) {
                    model.deleteHistoryAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Only this phone's history is deleted.")
            }
        }
    }
}

struct ActivityRow: View {
    let entry: IncidentHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ActivityText.causeTitle(entry.cause))
                .font(.headline)
            Text(format: "%@ • %@",
                entry.startedAt.formatted(date: .abbreviated, time: .shortened),
                ActivityText.duration(entry.durationSeconds))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(format: "Contacts alerted: %d", entry.contactsAlerted)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ActivityText.voiceOver(entry))
    }
}

struct ActivityDetailView: View {
    @StateObject private var model = ProtectViewModel.shared
    let entry: IncidentHistoryEntry
    @State private var showingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("What happened") {
                LabeledContent("Cause", value: ActivityText.causeTitle(entry.cause))
                LabeledContent(
                    "Started",
                    value: entry.startedAt.formatted(date: .abbreviated, time: .standard)
                )
                LabeledContent(
                    "Duration", value: ActivityText.duration(entry.durationSeconds)
                )
            }
            Section("Tracks") {
                ForEach(EscalationTrack.allCases, id: \.self) { track in
                    LabeledContent(
                        track.title,
                        value: entry.trackOutcomes[track.rawValue] ?? "not run"
                    )
                }
            }
            Section("Contacts") {
                LabeledContent(
                    "Alerted", value: "\(entry.contactsAlerted)"
                )
                if !entry.contactNames.isEmpty {
                    Text(entry.contactNames.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Evidence") {
                LabeledContent(
                    "Parts",
                    value: String(
                        format: String(localized: "%d saved, %d waiting"),
                        entry.evidenceSaved, entry.evidenceWaiting
                    )
                )
                if let link = entry.liveURL, let url = URL(string: link) {
                    Link("Open live link", destination: url)
                        .minTouchTarget()
                }
            }
            Section {
                Button("Delete this event", role: .destructive) {
                    showingDelete = true
                }
            }
        }
        .navigationTitle("SOS event")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this event?",
            isPresented: $showingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.deleteHistoryEntry(id: entry.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

enum ActivityText {
    static func causeTitle(_ cause: String) -> String {
        switch cause {
        case "noReply": String(localized: "No reply")
        case "unsafePhrase": String(localized: "Unsafe phrase")
        case "distressWord": String(localized: "Distress word")
        case "shouting": String(localized: "Shouting")
        case "gestures": String(localized: "Unwanted gestures")
        case "flag": String(localized: "Conversation flag")
        case "safeArrival": String(localized: "Safe-arrival timer")
        default: cause
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(format: String(localized: "%d s"), seconds)
        }
        return String(
            format: String(localized: "%d min %d s"),
            seconds / 60, seconds % 60
        )
    }

    static func voiceOver(_ entry: IncidentHistoryEntry) -> String {
        String(format: String(localized: "SOS on %@: %@, %@. Contacts alerted: %d."),
            entry.startedAt.formatted(date: .abbreviated, time: .shortened) as NSString,
            causeTitle(entry.cause) as NSString,
            duration(entry.durationSeconds) as NSString,
            entry.contactsAlerted)
    }
}
