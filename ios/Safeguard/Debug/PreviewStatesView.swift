#if DEBUG
    import SwiftUI

    /// Debug-only screen rendering every protection state plus mock SOS track
    /// cards, so all screens are reviewable in the Simulator without a camera.
    struct PreviewStatesView: View {
        var body: some View {
            ScrollView {
                VStack(spacing: DS.Spacing.medium) {
                    ForEach(ProtectionState.allCases, id: \.self) { state in
                        HStack(spacing: DS.Spacing.medium) {
                            ShieldRingView(state: state, size: 72)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.title).font(.headline)
                                Text(state.subtitle).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: DS.cornerRadius)
                        )
                    }

                    Text("SOS tracks (mock data)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.small)
                    StatusCardView(
                        title: "Route", subtitle: "Fastest safe route",
                        systemImage: "map.fill", status: .active
                    )
                    StatusCardView(
                        title: "Contacts", subtitle: "2 contacts alerted",
                        systemImage: "message.fill", status: .done
                    )
                    StatusCardView(
                        title: "Live stream", subtitle: "Reconnecting…",
                        systemImage: "video.fill", status: .retrying
                    )
                    StatusCardView(
                        title: "Cab", subtitle: "Finding nearest ride…",
                        systemImage: "car.fill", status: .starting
                    )

                    Text("Proximity (mock data)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.small)
                    ForEach(Proximity.allCases, id: \.self) { level in
                        HStack(spacing: DS.Spacing.medium) {
                            ShieldRingView(state: .monitoring, proximity: level, size: 72)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.title).font(.headline)
                                Text(level.symbolName).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding()
                        .background(
                            Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: DS.cornerRadius)
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("Preview states")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    #Preview {
        NavigationStack {
            PreviewStatesView()
        }
    }
#endif
