import SwiftUI

/// Dashboard card: set "I'll be safe by…", or tap "I'm safe" when there.
struct SafeArrivalCard: View {
    @StateObject private var store = SafeArrivalStore.shared
    @State private var minutes = 30

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            DSSectionHeader(title: String(localized: "Safe arrival"))
            if let deadline = store.deadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, deadline.timeIntervalSince(context.date))
                    Text(L10n.format("Be safe by %@ (%@ left)",
                                     deadline.formatted(date: .omitted, time: .shortened),
                                     SafeArrivalStore.clock(left)))
                        .font(.headline)
                        .monospacedDigit()
                }
                Button {
                    store.markSafe()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("I'm safe", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(.white)
                        .background(DS.Colors.ok, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                Text("If you do not tap this in time, an SOS countdown starts and you can still cancel it.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker("Minutes", selection: $minutes) {
                    ForEach(SafeArrivalStore.choices, id: \.self) { value in
                        Text(L10n.format("%d min", value)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Button("Start timer") {
                    store.start(minutes: minutes)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("Heading somewhere? Set a time. If you have not tapped I'm safe by then, Safeguard starts an SOS countdown. Keep the app installed and notifications on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .dsCard()
    }
}
