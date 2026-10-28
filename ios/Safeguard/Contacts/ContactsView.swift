import SwiftUI

struct ContactsView: View {
    @StateObject private var model = ProtectViewModel.shared
    @State private var newName = ""
    @State private var adding = false
    @State private var justAddedLink: URL?
    @State private var showingInviteSheet = false
    @State private var showingPhonePicker = false

    private let refreshTick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.sosContacts.contacts.isEmpty {
                        Text("No contacts yet. Add up to 5 people you trust.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.sosContacts.contacts, id: \.code) { contact in
                        contactRow(contact)
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text(
                        format: "Emergency contacts (%d/%d)",
                        model.sosContacts.contacts.count, SOSContactStore.maxContacts
                    )
                } footer: {
                    Text("Only people who agree get alerts. They press Start once in Telegram; nothing is sent before that.")
                }

                Section {
                    Button {
                        showingPhonePicker = true
                    } label: {
                        Label("Choose from your contacts", systemImage: "person.crop.circle.badge.plus")
                    }
                    .minTouchTarget()
                    .disabled(model.sosContacts.isFull)
                    TextField("Name", text: $newName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                    Button(adding ? String(localized: "Creating invite...") : String(localized: "Add contact")) {
                        addContact()
                    }
                    .minTouchTarget()
                    .disabled(adding || model.sosContacts.isFull || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    if model.sosContacts.isFull {
                        Text("At most 5 contacts. Remove one to add another.")
                    }
                }
            }
            .navigationTitle("Contacts")
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
                    ShareInviteView(link: link) {
                        showingInviteSheet = false
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contactRow(_ contact: SOSContact) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                    if let phone = contact.phone {
                        Text(phone).font(.footnote).foregroundStyle(.secondary)
                    }
                    if model.staleContactCodes.contains(contact.code) {
                        Text("This invite no longer works. Remove this contact and add them again.")
                            .font(.footnote)
                            .foregroundStyle(DS.Colors.warning)
                    } else {
                        Text(contact.linked ? String(localized: "Linked") : String(localized: "Waiting"))
                            .font(.footnote)
                            .foregroundStyle(contact.linked ? DS.Colors.ok : .secondary)
                    }
                }
                Spacer()
                if contact.linked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.Colors.ok)
                } else if let link = contact.link, let url = URL(string: link) {
                    ShareLink(item: url) {
                        Label("Invite on Telegram", systemImage: "paperplane")
                    }
                    .font(.footnote)
                    .minTouchTarget()
                }
            }
            Toggle(
                "This person agreed to be alerted",
                isOn: Binding(
                    get: { contact.agreed },
                    set: { model.setContactAgreed(code: contact.code, agreed: $0) }
                )
            )
            .font(.footnote)
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let contact = model.sosContacts.contacts[index]
            model.removeContact(code: contact.code)
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

private struct ShareInviteView: View {
    let link: URL
    let done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("Invite created")
                    .font(.title2.bold())
                Text("Send this link to your contact. They press Start once in Telegram, then they will get your SOS alerts.")
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
