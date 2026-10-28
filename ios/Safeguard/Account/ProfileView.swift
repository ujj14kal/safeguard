import PhotosUI
import SwiftUI

struct PhotoChooser: View {
    @Binding var image: UIImage?
    var title: LocalizedStringKey = "Choose a photo"
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label(title, systemImage: "photo.on.rectangle")
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let picked = UIImage(data: data)
                {
                    image = picked
                }
                item = nil
            }
        }
    }
}

struct ProfileView: View {
    @StateObject private var store = AccountStore.shared
    @State private var name = ""
    @State private var phone = ""
    @State private var picked: UIImage?
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: DS.Spacing.small) {
                        AvatarView(data: store.avatarData, name: name, size: 96)
                        PhotoChooser(
                            image: $picked,
                            title: store.avatarData == nil ? "Choose a photo" : "Change photo"
                        )
                        if store.avatarData != nil {
                            Button("Remove photo", role: .destructive) {
                                Task { await store.removeAvatar() }
                            }
                            .font(.subheadline)
                        }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } footer: {
                Text("Optional. Your photo is stored on the Safeguard server with your account.")
            }
            Section("Your profile") {
                TextField("Your name", text: $name)
                    .textInputAutocapitalization(.words)
                TextField("Phone (optional)", text: $phone)
                    .keyboardType(.phonePad)
                if let email = store.profile?.email {
                    LabeledContent("Email", value: email)
                }
                Button("Save") {
                    Task { saved = await store.updateProfile(name: name, phone: phone) }
                }
                if saved { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(DS.Colors.ok) }
            }
            if let error = store.errorMessage {
                Text(error).font(.footnote).foregroundStyle(DS.Colors.danger)
            }
        }
        .navigationTitle("Your profile")
        .onAppear {
            name = store.profile?.name ?? ""
            phone = store.profile?.phone ?? ""
            store.errorMessage = nil
            Task { await store.loadAvatar() }
        }
        .onChange(of: picked) { _, image in
            guard let image else { return }
            Task {
                await store.setAvatar(image)
                picked = nil
            }
        }
    }
}
