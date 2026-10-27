import MapKit
import SwiftUI
import UIKit

/// The SOS screen. Everything on it runs by itself (contacts alerted, live
/// page, nearest help, cab, recording); the one thing left to the wearer
/// is the police call, which never dials on its own.
struct SOSView: View {
    @ObservedObject var model: ProtectViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holdProgress: CGFloat = 0
    @State private var arrived = false

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(spacing: DS.Spacing.medium) {
                    header
                    mapCard
                    stepsCard
                    contactsCard
                    liveLinkCard
                    cabCard
                    evidenceRow
                    Color.clear.frame(height: 150)
                }
                .padding(.horizontal)
                .padding(.top, DS.Spacing.medium)
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived || reduceMotion ? 0 : 24)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SOS. Help is on the way.")
        .onAppear {
            withAnimation(DS.Motion.lively) { arrived = true }
        }
    }

    // MARK: Background and header

    private var background: some View {
        ZStack {
            DS.Colors.background
            LinearGradient(
                colors: [DS.Colors.danger.opacity(0.55), DS.Colors.danger.opacity(0.12), .clear],
                startPoint: .top, endPoint: .center
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.medium) {
            ZStack {
                PulsingDot(color: DS.Colors.danger, size: 40)
                    .scaleEffect(1.8)
                Image(systemName: "sos")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(DS.Colors.danger, in: Circle())
                    .shadow(color: DS.Colors.danger.opacity(0.6), radius: 14)
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 2) {
                Text("SOS is active")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                Text(causeText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let started = model.sosStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let secs = max(0, Int(context.date.timeIntervalSince(started)))
                    Text(String(format: "%02d:%02d", secs / 60, secs % 60))
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .accessibilityLabel(Text(format: "%d seconds since the SOS started", secs))
                }
            }
        }
        .padding(.top, DS.Spacing.small)
    }

    private var causeText: String {
        switch model.unsafeCause {
        case .noReply:
            return String(localized: "No reply — help is on the way")
        case .distressWord:
            return String(localized: "Distress call — recording and help are starting")
        default:
            return String(localized: "Help is on the way")
        }
    }

    // MARK: Automatic steps

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            DSSectionHeader(title: String(localized: "Happening automatically"))
            ForEach(EscalationTrack.allCases, id: \.self) { track in
                stepRow(track)
            }
        }
        .dsCard()
        .animation(DS.Motion.smooth, value: model.escalation.statuses)
    }

    private func stepRow(_ track: EscalationTrack) -> some View {
        let status = model.escalation.status(of: track)
        return HStack(spacing: DS.Spacing.medium) {
            ZStack {
                Circle().fill(stepColor(status).opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: stepIcon(track, status))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(stepColor(status))
                    .symbolEffect(.pulse, isActive: status == .running && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline)
                Text(stepDetail(track, status))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status == .running {
                SkeletonBar(width: 38, height: 8)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(format: "%@: %@", track.title, stepDetail(track, status)))
    }

    private func stepIcon(_ track: EscalationTrack, _ status: TrackStatus) -> String {
        switch status {
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        case .pending, .running:
            switch track {
            case .route: return "location.fill"
            case .contacts: return "person.2.fill"
            case .stream: return "dot.radiowaves.left.and.right"
            case .cab: return "car.fill"
            }
        }
    }

    private func stepColor(_ status: TrackStatus) -> Color {
        switch status {
        case .done: return DS.Colors.ok
        case .failed: return DS.Colors.warning
        case .pending: return .gray
        case .running: return DS.Colors.accent
        }
    }

    private func stepDetail(_ track: EscalationTrack, _ status: TrackStatus) -> String {
        switch status {
        case .pending:
            return String(localized: "Waiting to start")
        case .running:
            let attempt = model.escalation.attempts(of: track)
            if attempt > 1 { return L10n.format("Retrying (%d)", attempt) }
            switch track {
            case .route: return String(localized: "Finding the nearest help")
            case .contacts: return String(localized: "Alerting your contacts")
            case .stream: return String(localized: "Starting the live page")
            case .cab: return String(localized: "Preparing your ride")
            }
        case .done:
            switch track {
            case .route: return model.sosDestinationName ?? String(localized: "Route ready")
            case .contacts: return contactsSummary
            case .stream: return String(localized: "Live page is up")
            case .cab: return String(localized: "Uber ride ready")
            }
        case .failed(let reason):
            return L10n.format("Failed: %@", reason)
        }
    }

    private var contactsSummary: String {
        let sent = model.deliveryStatus.filter { $0.status == "sent" || $0.status == "dry-run" }.count
        return sent > 0 ? L10n.format("%d contacts alerted", sent) : String(localized: "Contacts alerted")
    }

    // MARK: Map

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if model.sosFix == nil {
                    ZStack {
                        DS.Colors.surfaceElevated
                        LoadingScreen(
                            title: String(localized: "Finding your location"),
                            subtitle: model.sosRouteMessage ?? String(localized: "Move to an open area if it takes long"),
                            symbol: "location.fill"
                        )
                    }
                } else {
                    SOSMapView(
                        fix: model.sosFix,
                        places: model.sosPlaces,
                        route: model.sosRoute,
                        destination: model.sosDestinationCoordinate,
                        destinationName: model.sosDestinationName
                    )
                    if model.sosRouteSearching && model.sosRoute == nil {
                        VStack {
                            Spacer()
                            Label("Looking for police and hospitals", systemImage: "magnifyingglass")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .safeguardPanel()
                                .shimmering()
                                .padding(.bottom, 10)
                        }
                    }
                }
            }
            .frame(height: 300)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: DS.cardRadius, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: DS.cardRadius, style: .continuous
            ))
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                destinationRow
                accuracyRow
                if model.sosDestinationCoordinate != nil { directionsButtons }
            }
            .padding(DS.Spacing.medium)
        }
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var destinationRow: some View {
        if let name = model.sosDestinationName {
            HStack(spacing: DS.Spacing.medium) {
                Image(systemName: model.sosPlaces.first(where: { $0.name == name })?.kind.symbol ?? "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    if let eta = model.sosDestinationETA {
                        Text(eta).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
        } else if let message = model.sosRouteMessage {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var accuracyRow: some View {
        if let fix = model.sosFix {
            let quality = LocationFixPolicy.quality(accuracy: fix.horizontalAccuracy)
            HStack(spacing: 8) {
                StatusPill(
                    text: LocationFixPolicy.accuracyText(fix.horizontalAccuracy),
                    symbol: quality == .precise ? "location.fill" : "location",
                    color: quality == .precise ? DS.Colors.ok : DS.Colors.warning
                )
                if model.sosPreciseOffHint {
                    Text("Precise Location is off for Safeguard")
                        .font(.caption)
                        .foregroundStyle(DS.Colors.warning)
                }
            }
        }
    }

    private var directionsButtons: some View {
        HStack(spacing: DS.Spacing.small) {
            Button {
                model.openDestinationInGoogleMaps()
            } label: {
                Label("Google Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Colors.buttonFill)
            Button {
                model.openDestinationInMaps()
            } label: {
                Label("Apple Maps", systemImage: "map.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(DS.Colors.accent)
        }
    }

    // MARK: Contacts, link, cab, evidence

    @ViewBuilder
    private var contactsCard: some View {
        if !model.deliveryStatus.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                DSSectionHeader(title: String(localized: "Your contacts"))
                ForEach(model.deliveryStatus, id: \.code) { outcome in
                    HStack(spacing: DS.Spacing.medium) {
                        Text(initial(outcome.name))
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(DS.Colors.accent.opacity(0.18), in: Circle())
                            .foregroundStyle(DS.Colors.accent)
                        Text(outcome.name ?? String(localized: "Contact"))
                        Spacer()
                        StatusPill(
                            text: deliveryText(outcome.status),
                            symbol: deliverySymbol(outcome.status),
                            color: deliveryColor(outcome.status)
                        )
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .dsCard()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func initial(_ name: String?) -> String {
        String((name ?? "?").trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private func deliveryText(_ status: String) -> String {
        switch status {
        case "sent": return String(localized: "Sent")
        case "dry-run": return String(localized: "Dry-run")
        case "failed": return String(localized: "Failed")
        default: return String(localized: "Waiting")
        }
    }

    private func deliverySymbol(_ status: String) -> String {
        switch status {
        case "sent": return "checkmark.circle.fill"
        case "dry-run": return "testtube.2"
        case "failed": return "exclamationmark.circle.fill"
        default: return "clock"
        }
    }

    private func deliveryColor(_ status: String) -> Color {
        switch status {
        case "sent": return DS.Colors.ok
        case "dry-run", "failed": return DS.Colors.warning
        default: return .gray
        }
    }

    @ViewBuilder
    private var liveLinkCard: some View {
        if let link = model.liveURL, let url = URL(string: link) {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                HStack {
                    PulsingDot(color: DS.Colors.danger, size: 8)
                    Text("Family can watch live").font(.headline)
                }
                Text(link)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: DS.Spacing.small) {
                    Button {
                        UIPasteboard.general.string = link
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        model.showToast(String(localized: "Link copied"))
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    ShareLink(item: url, message: Text("My Safeguard live page")) {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .tint(DS.Colors.accent)
            }
            .dsCard()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var cabCard: some View {
        if model.ridePickup != nil {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                HStack(spacing: DS.Spacing.medium) {
                    Image(systemName: "car.fill")
                        .font(.title2)
                        .foregroundStyle(DS.Colors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get a ride").font(.headline)
                        Text(rideSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    model.openUberRide()
                } label: {
                    Label("Open Uber with the trip filled in", systemImage: "arrow.up.forward.app.fill")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.Colors.buttonFill)
                Text("Your contacts also got a link to send a cab to you. You confirm the booking inside Uber; Safeguard keeps recording only while it is open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .dsCard()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var rideSummary: String {
        if let dropoff = model.rideDropoff {
            return L10n.format("From your location to %@", dropoff.nickname)
        }
        return String(localized: "From your location (choose where to in Uber)")
    }

    @ViewBuilder
    private var evidenceRow: some View {
        if let status = model.evidenceStatus {
            Label(status, systemImage: "record.circle")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Actions

    /// Pinned at the bottom: the police call (manual by design) and the
    /// deliberate three-second hold to end.
    private var actionBar: some View {
        VStack(spacing: DS.Spacing.small) {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                if let url = URL(string: "tel:112") { openURL(url) }
            } label: {
                Label("Call police (112)", systemImage: "phone.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(.white)
                    .background(DS.Colors.danger, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Starts a phone call to the emergency number. Nothing dials by itself.")
            holdToEnd
        }
        .padding(.horizontal)
        .padding(.top, DS.Spacing.small)
        .padding(.bottom, DS.Spacing.small)
        .background(.ultraThinMaterial)
    }

    private var holdToEnd: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.1))
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.28))
                    .frame(width: proxy.size.width * holdProgress)
            }
            Text("Hold 3 s to end SOS")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .frame(height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onLongPressGesture(
            minimumDuration: 3,
            pressing: { pressing in
                if pressing {
                    withAnimation(.linear(duration: 3)) { holdProgress = 1 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
                }
            },
            perform: {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                model.endSOSButtonHeld()
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold 3 seconds to end the SOS")
        .accessibilityAddTraits(.isButton)
    }
}
