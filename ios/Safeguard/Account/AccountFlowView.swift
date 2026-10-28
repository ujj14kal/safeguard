import SwiftUI

struct AccountFlowView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case create, signIn
        var id: String { rawValue }
    }

    @StateObject private var store = AccountStore.shared
    @AppStorage("wearerName") private var wearerName = ""
    @State private var mode: Mode = .create
    @State private var name = ""
    @State private var email = ""
    @State private var password: String = ""
    @State private var phone = ""
    @State private var guardianCode: String = ""
    @State private var consent = false
    @State private var showPassword = false
    @State private var photo: UIImage?
    @FocusState private var focus: Field?

    private enum Field { case name, email, password, phone, guardian }

    var onFinished: (() -> Void)?
    var allowSkip = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            if let profile = store.profile {
                signedInCard(profile)
            } else {
                header
                Picker("", selection: $mode) {
                    Text("Create account").tag(Mode.create)
                    Text("Sign in").tag(Mode.signIn)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in store.errorMessage = nil }
                form
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(DS.Colors.danger)
                        .transition(.opacity)
                }
                if store.needsConfirmation {
                    Label(
                        "Check your email and open the link to confirm, then sign in here.",
                        systemImage: "envelope.badge"
                    )
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.warning)
                }
                Button(action: submit) {
                    HStack(spacing: 10) {
                        if store.isBusy { ProgressView().tint(.white) }
                        Text(mode == .create ? String(localized: "Create account") : String(localized: "Sign in"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(store.isBusy)
                if store.serverUnreachable {
                    offlineOffer
                }
                if allowSkip {
                    Button("Continue without an account") { onFinished?() }
                        .font(.subheadline.weight(.semibold))
                        .tint(DS.Colors.accent)
                        .frame(maxWidth: .infinity)
                        .minTouchTarget()
                    Text("You can add one later in Settings. Without one, your profile is not backed up.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(DS.Motion.smooth, value: mode)
        .animation(DS.Motion.smooth, value: store.errorMessage)
        .onAppear { if name.isEmpty { name = wearerName } }
    }

    private var offlineOffer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Can't reach the Safeguard server. You can still use the app on this phone and sign in later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if mode == .signIn {
                field("Your name", text: $name, symbol: "person.fill", focus: .name)
                    .textInputAutocapitalization(.words)
            }
            Button("Continue offline for now") {
                if store.continueOffline(name: name) {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    onFinished?()
                }
            }
            .buttonStyle(.bordered)
            .tint(DS.Colors.accent)
            .minTouchTarget()
        }
        .padding(14)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(mode == .create ? String(localized: "Create your account") : String(localized: "Welcome back"))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Your account keeps your profile safe and ready on any phone.")
                .foregroundStyle(.secondary)
        }
    }

    private var form: some View {
        VStack(spacing: DS.Spacing.small) {
            if mode == .create {
                field("Your name", text: $name, symbol: "person.fill", focus: .name)
                    .textInputAutocapitalization(.words)
                    .textContentType(.name)
            }
            field("Email", text: $email, symbol: "envelope.fill", focus: .email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .textContentType(.emailAddress)
            passwordField
            if mode == .create {
                photoRow
                field("Phone (optional)", text: $phone, symbol: "phone.fill", focus: .phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                field("Guardian code (optional)", text: $guardianCode, symbol: "shield.lefthalf.filled", focus: .guardian)
                    .textInputAutocapitalization(.characters)
                passwordHint
                consentRow
            }
        }
    }

    private var photoRow: some View {
        HStack(spacing: 14) {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: 52, height: 52).clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 52)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Profile photo (optional)").font(.subheadline.weight(.semibold))
                PhotoChooser(image: $photo, title: photo == nil ? "Choose a photo" : "Change photo")
                    .font(.footnote)
            }
            Spacer()
        }
        .padding(14)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, symbol: String, focus: Field) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 22)
            TextField(title, text: text)
                .focused($focus, equals: focus)
                .autocorrectionDisabled()
        }
        .padding(14)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var passwordField: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 22)
            Group {
                if showPassword {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .focused($focus, equals: .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(mode == .create ? .newPassword : .password)
            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(showPassword ? String(localized: "Hide password") : String(localized: "Show password"))
        }
        .padding(.leading, 14)
        .padding(.vertical, 2)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var passwordHint: some View {
        if !password.isEmpty, let problem = AccountValidation.passwordProblem(password) {
            Text(problem).font(.footnote).foregroundStyle(DS.Colors.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var consentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $consent) {
                Text("I agree to the privacy notice")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Safeguard stores your name, email, optional phone and language in your account. Your password goes straight to the sign-in service and is never stored by Safeguard. Contacts you pick stay on this phone. You can delete your account any time in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func signedInCard(_ profile: AccountProfile) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 56))
                .foregroundStyle(DS.Colors.ok)
            Text("You're signed in")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.headline)
                Text(profile.email).font(.subheadline).foregroundStyle(.secondary)
            }
            .dsCard()
            if let onFinished {
                Button("Continue") { onFinished() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func submit() {
        focus = nil
        Task {
            let ok: Bool
            switch mode {
            case .create:
                ok = await store.signUp(
                    name: name, email: email, password: password, phone: phone,
                    consent: consent, language: AppLanguage.alertLang, guardianCode: guardianCode
                )
            case .signIn:
                ok = await store.signIn(email: email, password: password)
            }
            if ok, store.isSignedIn {
                if mode == .create, let photo { await store.setAvatar(photo) }
                if mode == .signIn { await store.loadAvatar() }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                password.removeAll()
                onFinished?()
            }
        }
    }
}

struct SetupAccountStep: View {
    var onFinished: () -> Void

    var body: some View {
        AccountFlowView(onFinished: onFinished, allowSkip: false)
    }
}
