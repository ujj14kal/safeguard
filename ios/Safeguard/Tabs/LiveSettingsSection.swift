import SwiftUI

/// Settings: the standing live link (created on approval, shared by hand,
/// sent to emergency contacts automatically in an SOS) and the guardian
/// code (who may review the recordings).
struct LiveSettingsSection: View {
    @StateObject private var links = LiveLinkStore.shared
    @StateObject private var model = ProtectViewModel.shared
    @State private var confirmCreate = false
    @State private var confirmDelete = false
    @State private var codeText = ""
    @AppStorage("wearerName") private var wearerName = ""

    var body: some View {
        Group {
            liveSection
            guardianSection
        }
        .task { await links.refreshLink(wearerName: wearerName) }
        .confirmationDialog(
            "Create your live link?", isPresented: $confirmCreate, titleVisibility: .visible
        ) {
            Button("Create my live link") {
                Task { await links.createLink(wearerName: wearerName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone with the link can see your location, camera and sound while you are live or in an SOS. Share it only with people you trust. You can delete it any time.")
        }
        .confirmationDialog(
            "Delete this link?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete the link", role: .destructive) {
                Task { await links.deleteLink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The address stops working for everyone who has it.")
        }
    }

    private var liveSection: some View {
        Section {
            if let url = links.url {
                Text(url)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button("Copy") {
                        UIPasteboard.general.string = url
                        model.showToast(String(localized: "Link copied"))
                    }
                    if let link = URL(string: url) {
                        ShareLink(item: link, message: Text("Watch my live location and video")) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .buttonStyle(.bordered)
                if model.liveStreaming {
                    Button("Stop live stream", role: .destructive) { model.stopLiveStream() }
                } else {
                    Button("Start live stream") { Task { await model.startLiveStream() } }
                }
                Button("Delete this link", role: .destructive) { confirmDelete = true }
            } else {
                Button("Create my live link") { confirmCreate = true }
                    .disabled(links.isBusy)
            }
            if let error = links.errorMessage {
                Text(error).font(.footnote).foregroundStyle(DS.Colors.danger)
            }
        } header: {
            Text("Live stream")
        } footer: {
            Text("The same link works for every live stream and is sent to your emergency contacts automatically in an SOS. Starting a live stream shares nothing by itself: you send the link to whoever you choose.")
        }
    }

    private var guardianSection: some View {
        Section {
            if let code = links.guardianCode {
                LabeledContent("Guardian code", value: code)
                Button("Remove guardian", role: .destructive) { links.clearGuardian() }
            } else {
                TextField("XXXX-XXXX-XXXX", text: $codeText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Save guardian code") {
                    Task {
                        if await links.setGuardian(code: codeText) { codeText = "" }
                    }
                }
                .disabled(links.isBusy || codeText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Guardian")
        } footer: {
            Text("Your guardian gets a code from the guardian page and gives it to you. With it they can watch your recordings, read-only. Remove it any time to stop new recordings reaching them.")
        }
    }
}
