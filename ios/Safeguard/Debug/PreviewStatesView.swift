#if DEBUG
    import SwiftUI

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

                    Text("HUD boxes (mock data)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.small)
                    PersonBoxOverlay(
                        tracks: [
                            Track(
                                id: 1,
                                box: CGRect(x: 0.05, y: 0.55, width: 0.16, height: 0.22),
                                confidence: 0.9, age: 10, missed: 0
                            ),
                            Track(
                                id: 2,
                                box: CGRect(x: 0.30, y: 0.40, width: 0.22, height: 0.35),
                                confidence: 0.9, age: 10, missed: 0
                            ),
                            Track(
                                id: 3,
                                box: CGRect(x: 0.62, y: 0.30, width: 0.28, height: 0.50),
                                confidence: 0.9, age: 10, missed: 0
                            ),
                        ],
                        frameSize: CGSize(width: 720, height: 1280),
                        scores: [1: 0.12, 2: 0.34, 3: 0.62],
                        config: ThreatConfig()
                    )
                    .frame(height: 220)
                    .background(
                        Color.black, in: RoundedRectangle(cornerRadius: DS.cornerRadius)
                    )
                    Text("Lilac clear, yellow near, red too close + alerting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("HUD pills (mock data)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.small)
                    ForEach(mockPills, id: \.text) { pill in
                        Label(pill.text, systemImage: pill.symbol)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .safeguardPanel()
                    }

                    Text("Stay-quiet cue (mock data)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.small)
                    Text(SafetyConfig().listeningCueText)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .safeguardPanel()

                    Text("Buttons")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.Spacing.small)
                    Button("Primary") {}
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Secondary") {}
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Destructive", role: .destructive) {}
                        .buttonStyle(DestructiveButtonStyle())
                    Button {} label: {
                        Image(systemName: "moon.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                    .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("Preview states")
            .navigationBarTitleDisplayMode(.inline)
        }

    private var mockPills: [HudStatus] {
        [
            HudStatus.resolve(),
            HudStatus.resolve(listenerLive: true),
            HudStatus.resolve(proximity: .near),
            HudStatus.resolve(proximity: .tooClose),
            HudStatus.resolve(alert: true),
            HudStatus.resolve(listeningWindow: true),
            HudStatus.resolve(asking: true),
            HudStatus.resolve(safe: true),
        ]
    }
}

    #Preview {
        NavigationStack {
            PreviewStatesView()
        }
    }
#endif
