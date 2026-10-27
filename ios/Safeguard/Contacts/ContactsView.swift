import SwiftUI

/// Emergency contacts tab: up to 5 contacts, invited over Telegram.
/// A contact gets SOS alerts only after pressing Start on their link.
struct ContactsView: View {
    @StateObject private var model = ProtectViewModel.shared
    @State private var newName = ""
    @State private var adding = false
    @State private var justAddedLink: URL?
    @State private var showingInviteSheet = false

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
                    TextField("Name", text: $newName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                    Button(adding ? "Creating invite..." : "Add contact") {
                        addContact()
                    }
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
                // Poll while anyone is still unlinked; linked state sticks.
                if model.sosContacts.contacts.contains(where: { !$0.linked }) {
                    model.refreshContacts()
                }
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
                    Text(contact.linked ? "Linked" : "Waiting")
                        .font(.footnote)
                        .foregroundStyle(contact.linked ? .green : .secondary)
                }
                Spacer()
                if contact.linked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let link = contact.link, let url = URL(string: link) {
                    ShareLink(item: url) {
                        Label("Invite on Telegram", systemImage: "paperplane")
                    }
                    .font(.footnote)
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

/// Share sheet shown right after an invite is created.
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
