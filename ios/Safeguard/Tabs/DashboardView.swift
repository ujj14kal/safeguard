import SwiftUI
import UIKit

struct DashboardView: View {
    @StateObject private var model = ProtectViewModel.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("wearerName") private var wearerName = ""
    @StateObject private var account = AccountStore.shared
    @State private var loaded = false
    @State private var permissions: [SetupPermission: PermissionStatus] = [:]

    private var items: [ReadinessItem] {
        Readiness.items(ReadinessInput(
            camera: permissions[.camera] ?? .notAsked,
            microphone: permissions[.microphone] ?? .notAsked,
            speech: permissions[.speech] ?? .notAsked,
            location: permissions[.location] ?? .notAsked,
            backendReachable: model.isProtecting ? model.backendStatus?.reachable : model.idleBackendReachable,
            contactCount: model.sosContacts.contacts.count,
            linkedCount: model.sosContacts.linkedCodes.count,
            sendsRealAlerts: model.sendRealAlerts
        ))
    }

    private var stats: DashboardStats { DashboardStats.from(model.history.entries) }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.background.ignoresSafeArea()
                if !loaded {
                    skeleton
                        .transition(.opacity)
                } else {
                    ScrollView {
                        VStack(spacing: DS.Spacing.large) {
                            heroCard
                            readinessCard
                            statsGrid
                            recentCard
                            SafeArrivalCard()
                            emergencyCard
                        }
                        .padding(.horizontal)
                        .padding(.bottom, DS.Spacing.xLarge)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await refresh() }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .navigationTitle(greeting)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .safeguardOpenSettings, object: nil)
                    } label: {
                        AvatarView(data: account.avatarData, name: wearerName, size: 34)
                    }
                }
            }
        }
        .task {
            await account.refreshProfile()
            await refresh()
            withAnimation(DS.Motion.smooth) { loaded = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var greeting: String {
        let name = wearerName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? String(localized: "Dashboard") : L10n.format("Hello, %@", name)
    }

    private func refresh() async {
        for permission in SetupPermission.allCases {
            permissions[permission] = SetupPermissions.status(of: permission)
        }
        model.refreshContacts()
        model.checkBackend()
        try? await Task.sleep(for: .milliseconds(450))
    }

    private var skeleton: some View {
        VStack(spacing: DS.Spacing.large) {
            VStack(spacing: DS.Spacing.medium) {
                SkeletonBar(width: 120, height: 120)
                SkeletonBar(width: 180, height: 18)
                SkeletonBar(height: 52)
            }
            .dsCard()
            VStack(spacing: DS.Spacing.medium) {
                SkeletonRow(); SkeletonRow(); SkeletonRow()
            }
            .dsCard()
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, DS.Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your dashboard")
    }

    private var heroCard: some View {
        VStack(spacing: DS.Spacing.medium) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [heroColor.opacity(0.35), .clear],
                        center: .center, startRadius: 8, endRadius: 90
                    ))
                    .frame(width: 180, height: 180)
                Circle()
                    .strokeBorder(heroColor.opacity(0.9), lineWidth: 6)
                    .frame(width: 112, height: 112)
                Image(systemName: model.isProtecting ? "checkmark.shield.fill" : "shield")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(heroColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: 150)
            Text(model.isProtecting ? String(localized: "You are protected") : String(localized: "Not protecting"))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .contentTransition(.opacity)
            Text(heroSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.isProtecting {
                Button("Stop protecting", role: .destructive) {
                    withAnimation(DS.Motion.smooth) { model.stop() }
                }
                .buttonStyle(DestructiveButtonStyle())
            } else {
                Button {
                    NotificationCenter.default.post(name: .safeguardGoBack, object: nil)
                    Task { await model.startCamera() }
                } label: {
                    Label("Start protecting", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .dsCard()
        .animation(DS.Motion.smooth, value: model.isProtecting)
    }

    private var heroColor: Color {
        model.isProtecting ? DS.Colors.ok : DS.Colors.accent
    }

    private var heroSubtitle: String {
        if model.isProtecting {
            return String(localized: "Watching for threats and listening for your safe words.")
        }
        let problems = items.filter { $0.level == .problem }.count
        if problems > 0 {
            return L10n.format("Items to fix before you start: %d", problems)
        }
        return String(localized: "Everything is ready. Tap start when you head out.")
    }

    private var readinessCard: some View {
        let list = items
        let ready = Readiness.readyCount(list)
        return VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            DSSectionHeader(
                title: String(localized: "Readiness"),
                trailing: L10n.format("%d of %d ready", ready, list.count)
            )
            ProgressView(value: Double(ready), total: Double(max(list.count, 1)))
                .tint(ready == list.count ? DS.Colors.ok : DS.Colors.accent)
                .animation(DS.Motion.smooth, value: ready)
            ForEach(list) { item in
                readinessRow(item)
            }
        }
        .dsCard()
    }

    private func readinessRow(_ item: ReadinessItem) -> some View {
        let color = levelColor(item.level)
        return Button {
            performFix(item.fix)
        } label: {
            HStack(spacing: DS.Spacing.medium) {
                Image(systemName: item.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 36, height: 36)
                    .background(color.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: item.level == .ok ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(item.level == .ok ? DS.Colors.ok : .secondary)
                    .font(item.level == .ok ? .body : .footnote.weight(.semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.fix == .none)
        .accessibilityElement(children: .combine)
    }

    private func levelColor(_ level: ReadinessLevel) -> Color {
        switch level {
        case .ok: return DS.Colors.ok
        case .warning: return DS.Colors.warning
        case .problem: return DS.Colors.danger
        }
    }

    private func performFix(_ fix: ReadinessFix) {
        switch fix {
        case .systemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .contacts:
            NotificationCenter.default.post(name: .safeguardOpenContacts, object: nil)
        case .settingsTab:
            NotificationCenter.default.post(name: .safeguardOpenSettings, object: nil)
        case .none:
            break
        }
    }

    private var statsGrid: some View {
        let s = stats
        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
            DSSectionHeader(title: String(localized: "Last 30 days"))
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                statTile(value: "\(s.eventsLast30Days)", label: String(localized: "SOS events"), symbol: "sos")
                statTile(value: "\(s.contactsAlerted)", label: String(localized: "Contact alerts"), symbol: "person.2.fill")
                statTile(value: "\(s.evidenceSaved)", label: String(localized: "Recording parts saved"), symbol: "record.circle")
                statTile(
                    value: s.averageDurationSeconds == 0 ? "–" : ActivityText.duration(s.averageDurationSeconds),
                    label: String(localized: "Average SOS length"), symbol: "timer"
                )
            }
        }
    }

    private func statTile(value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .dsCard()
        .accessibilityElement(children: .combine)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            DSSectionHeader(title: String(localized: "Recent SOS"))
            if model.history.entries.isEmpty {
                HStack(spacing: DS.Spacing.medium) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(DS.Colors.ok)
                    Text("No SOS events. Nothing to review.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.history.entries.prefix(3), id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ActivityText.causeTitle(entry.cause)).font(.subheadline.weight(.semibold))
                        Text(format: "%@ • %@",
                             entry.startedAt.formatted(date: .abbreviated, time: .shortened),
                             ActivityText.duration(entry.durationSeconds))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(ActivityText.voiceOver(entry))
                }
                Button("See all activity") {
                    NotificationCenter.default.post(name: .safeguardOpenActivity, object: nil)
                }
                .font(.subheadline.weight(.semibold))
                .tint(DS.Colors.accent)
            }
        }
        .dsCard()
    }

    private var emergencyCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            DSSectionHeader(title: String(localized: "Emergency"))
            Button {
                if let url = URL(string: "tel:112") { openURL(url) }
            } label: {
                Label("Call police (112)", systemImage: "phone.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(.white)
                    .background(DS.Colors.danger, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .tapHaptic(.medium)
            HStack(spacing: DS.Spacing.small) {
                helplineButton(Helplines.women, symbol: "figure.stand.dress")
                helplineButton(Helplines.domesticAbuse, symbol: "heart.circle.fill")
            }
            HStack(spacing: DS.Spacing.small) {
                nearbyButton(.police, title: String(localized: "Police near me"), symbol: "building.columns.fill")
                nearbyButton(.hospital, title: String(localized: "Hospitals near me"), symbol: "cross.case.fill")
            }
            Text("Safeguard never dials by itself. Everything else in an SOS runs automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .dsCard()
    }

    private func helplineButton(_ line: Helplines.Line, symbol: String) -> some View {
        Button {
            if let url = Helplines.dialURL(line) { openURL(url) }
        } label: {
            Label(LocalizedStringKey(line.titleKey), systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .tapHaptic(.light)
    }

    private func nearbyButton(_ place: Helplines.Place, title: String, symbol: String) -> some View {
        Button {
            if let url = Helplines.mapsURL(for: place) { openURL(url) }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .tapHaptic(.light)
    }
}
