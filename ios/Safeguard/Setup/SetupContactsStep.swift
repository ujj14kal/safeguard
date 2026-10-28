import SwiftUI

struct SetupContactsStep: View {
    @StateObject private var model = ProtectViewModel.shared
    @State private var newName = ""
    @State private var adding = false
    @State private var showingInviteSheet = false
    @State private var justAddedLink: URL?
    @State private var showingPhonePicker = false

    private let refreshTick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Text("Trusted contacts")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Add at least 2 people who agreed to be alerted. A contact receives alerts ONLY after they open the invite link and press Start in Telegram.")
                .foregroundStyle(.secondary)
            Text(format: "Agreed so far: %d of 2 needed", model.sosContacts.agreedCount)
                .font(.headline)
                .foregroundStyle(
                    model.sosContacts.agreedCount >= 2 ? DS.Colors.ok : DS.Colors.warning
                )
            ForEach(model.sosContacts.contacts, id: \.code) { contact in
                contactRow(contact)
                Divider()
            }
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Button {
                    showingPhonePicker = true
                } label: {
                    Label("Choose from your contacts", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.sosContacts.isFull)
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                Button(adding ? String(localized: "Creating invite...") : String(localized: "Add contact")) {
                    addContact()
                }
                .buttonStyle(.borderedProminent)
                .minTouchTarget()
                .disabled(
                    adding || model.sosContacts.isFull ||
                        newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                if model.sosContacts.isFull {
                    Text("At most 5 contacts. Remove one to add another.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refreshContacts() }
        .onReceive(refreshTick) { _ in
            if model.sosContacts.contacts.contains(where: { !$0.linked }) {
                model.refreshContacts()
            }
        }
        .sheet(isPresented: $showingPhonePicker) {
            PhoneContactPicker(
                onPick: { person, agreed in
                    let link = await model.inviteContact(name: person.name, phone: person.phone)
                    await MainActor.run {
                        if link != nil, let code = model.sosContacts.contacts.last?.code {
                            model.setContactAgreed(code: code, agreed: agreed)
                        }
                        justAddedLink = link
                        showingInviteSheet = link != nil
                    }
                },
                isAdded: { model.sosContacts.containsPhone($0.phone) }
            )
        }
        .sheet(isPresented: $showingInviteSheet) {
            if let link = justAddedLink {
                SetupInviteSheet(link: link) { showingInviteSheet = false }
            }
        }
    }

    private func contactRow(_ contact: SOSContact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(contact.name)
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    model.removeContact(code: contact.code)
                } label: {
                    Image(systemName: "trash")
                }
                .minTouchTarget()
                .accessibilityLabel(Text(format: "Remove %@", contact.name))
            }
            Toggle(
                "This person agreed to be alerted",
                isOn: Binding(
                    get: { contact.agreed },
                    set: { model.setContactAgreed(code: contact.code, agreed: $0) }
                )
            )
            .font(.footnote)
            HStack {
                Text(contact.linked ? String(localized: "Linked") : String(localized: "Waiting for them to press Start"))
                    .font(.footnote)
                    .foregroundStyle(contact.linked ? DS.Colors.ok : .secondary)
                Spacer()
                if !contact.linked, let link = contact.link, let url = URL(string: link) {
                    ShareLink(item: url) {
                        Label("Invite on Telegram", systemImage: "paperplane")
                    }
                    .font(.footnote)
                    .minTouchTarget()
                }
            }
        }
    }

    private func addContact() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !adding else { return }
        adding = true
        Task {
            let link = await model.inviteContact(name: name)
            await MainActor.run {
                adding = false
                newName = ""
                justAddedLink = link
                showingInviteSheet = link != nil
            }
        }
    }
}

private struct SetupInviteSheet: View {
    let link: URL
    let done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Spacing.medium) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("Invite created")
                    .font(.title2.bold())
                Text("Send this link to your contact. Only after they open it and press Start will they receive your SOS alerts.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                ShareLink(item: link) {
                    Label("Invite on Telegram", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .minTouchTarget()
                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
    }
}
