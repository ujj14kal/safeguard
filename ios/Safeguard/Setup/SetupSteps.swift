import SwiftUI
import UIKit

struct SetupPermissionsStep: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var statuses: [SetupPermission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Text("A few permissions")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Each one is asked separately, with the reason first. Saying no never stops setup — but some features will not work.")
                .foregroundStyle(.secondary)
            ForEach(SetupPermission.allCases) { permission in
                permissionRow(permission)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        var next: [SetupPermission: PermissionStatus] = [:]
        for permission in SetupPermission.allCases {
            next[permission] = SetupPermissions.status(of: permission)
        }
        statuses = next
    }

    private func permissionRow(_ permission: SetupPermission) -> some View {
        let status = statuses[permission] ?? .notAsked
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                        .font(.headline)
                    Text(permission.reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(status)
            }
            permissionAction(permission, status: status)
            Divider()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func permissionAction(
        _ permission: SetupPermission, status: PermissionStatus
    ) -> some View {
        if status == .notAsked {
            Button("Allow") {
                Task {
                    await SetupPermissions.request(permission)
                    refresh()
                }
            }
            .buttonStyle(.borderedProminent)
            .minTouchTarget()
        }
        if status == .denied {
            Label(permission.missingImpact, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(DS.Colors.warning)
            Button("Turn on in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.bordered)
            .minTouchTarget()
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: PermissionStatus) -> some View {
        if status == .granted {
            Label("On", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DS.Colors.ok)
        } else if status == .denied {
            Label("Off", systemImage: "xmark.circle.fill")
                .foregroundStyle(DS.Colors.danger)
        } else {
            Label("Ask me", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

struct SetupListeningStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Text("Listening choices")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Each choice says what it hears and what leaves your phone. You can change these anytime in Settings.")
                .foregroundStyle(.secondary)
            ForEach(ListeningChoices.all) { choice in
                ListeningToggle(choice)
                Divider()
            }
            Text("Recording laws differ by country: check yours before switching listening on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
