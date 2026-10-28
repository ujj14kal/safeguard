import SwiftUI
import UIKit

struct PhoneContactPicker: View {
    let onPick: (PhoneContact, Bool) async -> Void
    let isAdded: (PhoneContact) -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var access = PhoneContactsAccess.status()
    @State private var loading = false
    @State private var contacts: [PhoneContact] = []
    @State private var query = ""
    @State private var chosen: PhoneContact?
    @State private var working = false

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.background.ignoresSafeArea()
                switch access {
                case .notAsked: intro
                case .denied: denied
                case .granted: list
                }
            }
            .navigationTitle("Your contacts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { if access == .granted { await load() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                let now = PhoneContactsAccess.status()
                if now != access {
                    access = now
                    if now == .granted { Task { await load() } }
                }
            }
        }
    }

    private var intro: some View {
        VStack(spacing: DS.Spacing.large) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 64))
                .foregroundStyle(DS.Colors.accent)
            Text("Pick people you trust")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("Safeguard needs to read your contacts so you can choose who to alert. It only reads names and numbers, keeps your choices on this phone, and never uploads your address book.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Allow access to contacts") {
                Task {
                    let granted = await PhoneContactsAccess.request()
                    access = granted ? .granted : .denied
                    if granted { await load() }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(DS.Spacing.large)
    }

    private var denied: some View {
        VStack(spacing: DS.Spacing.large) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(DS.Colors.warning)
            Text("Contacts access is off")
                .font(.system(.title2, design: .rounded, weight: .bold))
            Text("Turn it on in Settings to pick people from your contacts. You can also add someone by typing their name.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(DS.Spacing.large)
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            VStack(spacing: DS.Spacing.medium) {
                ForEach(0..<7, id: \.self) { _ in SkeletonRow() }
                Spacer()
            }
            .padding()
        } else {
            let shown = PhoneContactList.filter(contacts, query: query)
            List {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                }
                ForEach(shown) { contact in
                    row(contact)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "Search contacts")
            .confirmationDialog(
                chosen.map { L10n.format("Add %@?", $0.name) } ?? "",
                isPresented: Binding(get: { chosen != nil }, set: { if !$0 { chosen = nil } }),
                titleVisibility: .visible
            ) {
                Button("Yes, they agreed") {
                    if let person = chosen { add(person, agreed: true) }
                }
                Button("Cancel", role: .cancel) { chosen = nil }
            } message: {
                Text("Only add people who agreed to be alerted. You will get a Telegram invite link to send them.")
            }
            .overlay {
                if working {
                    LoadingScreen(title: String(localized: "Creating invite"), symbol: "paperplane.fill")
                        .background(.ultraThinMaterial)
                }
            }
        }
    }

    private func row(_ contact: PhoneContact) -> some View {
        let added = isAdded(contact)
        return Button {
            chosen = contact
        } label: {
            HStack(spacing: DS.Spacing.medium) {
                Text(String(contact.name.prefix(1)).uppercased())
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(DS.Colors.accent.opacity(0.18), in: Circle())
                    .foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).foregroundStyle(.primary)
                    if let phone = contact.phone {
                        Text(phone).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if added {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(DS.Colors.ok)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(added ? Text(format: "%@, already added", contact.name) : Text(verbatim: contact.name))
    }

    private func load() async {
        loading = true
        contacts = await PhoneContactsAccess.fetch()
        withAnimation(DS.Motion.smooth) { loading = false }
    }

    private func add(_ person: PhoneContact, agreed: Bool) {
        chosen = nil
        working = true
        Task {
            await onPick(person, agreed)
            working = false
            dismiss()
        }
    }
}
