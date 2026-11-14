import SwiftUI

private struct OpenProfilesKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openProfiles: () -> Void {
        get { self[OpenProfilesKey.self] }
        set { self[OpenProfilesKey.self] = newValue }
    }
}

/// Uses the same authenticated profile proof and PIN/password flow as the AIOStreams web app.
struct ProfilePickerView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [PickableProfile] = []
    @State private var selected: PickableProfile?
    @State private var secret = ""
    @State private var loading = true
    @State private var working = false
    @State private var error: String?
    @State private var legacy = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.px(32)) {
                Text("Who’s watching?").font(Theme.font(40, .bold))
                if let selected {
                    Text(selected.user.name ?? "Profile").font(Theme.font(Theme.xl2, .semibold))
                    SecureField(selected.needs == "pin" ? "PIN" : "Password", text: $secret)
                        .frame(width: Theme.px(360))
                        .onSubmit { switchTo(selected) }
                    if selected.needs == "password-pin" {
                        Text("Enter password/PIN.").foregroundStyle(Theme.gray400)
                    }
                    Button(working ? "Switching…" : "Continue") { switchTo(selected) }
                        .buttonStyle(PrimaryPillStyle()).disabled(working || secret.isEmpty)
                    Button("Choose another profile") { self.selected = nil; secret = ""; error = nil }
                        .buttonStyle(SecondaryPillStyle()).disabled(working)
                } else if loading {
                    ProgressView()
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: Theme.px(40)) {
                            ForEach(profiles) { profile in
                                Button {
                                    if profile.id == session.userId { dismiss() }
                                    else if profile.needs != nil { selected = profile; secret = ""; error = nil }
                                    else { switchTo(profile) }
                                } label: {
                                    VStack(spacing: Theme.px(12)) {
                                        UserAvatar(user: profile.user, url: avatar(profile))
                                        if profile.id == session.userId {
                                            Text("Watching now").font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
                                        }
                                    }
                                    .padding(Theme.px(16))
                                }
                                .buttonStyle(CardStyle(radius: Theme.px(20)))
                                .disabled(working)
                            }
                        }
                        .padding(Theme.px(24))
                    }
                    .frame(maxHeight: Theme.px(250))
                    if profiles.isEmpty && error == nil {
                        Text("This server did not return any profiles.").foregroundStyle(Theme.gray400)
                    }
                }
                ErrorText(text: error)
                if !loading && error != nil && selected == nil {
                    Button("Try again") { Task { await load() } }.buttonStyle(SecondaryPillStyle())
                }
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryPillStyle()).disabled(working)
            }
            .padding(Theme.px(56))
        }
        .task { await load() }
        .onExitCommand {
            if selected != nil { selected = nil; secret = ""; error = nil } else { dismiss() }
        }
    }

    private func avatar(_ profile: PickableProfile) -> URL? {
        guard let client = session.client else { return nil }
        if let image = profile.avatar, let url = URL(string: image, relativeTo: client.base),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url.absoluteURL }
        return client.url("/Users/\(profile.id)/Images/Primary", ["fillHeight": "192"])
    }

    @MainActor private func load() async {
        guard let client = session.client else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            do {
                profiles = try await client.get("/AIOStreams/Users")
                legacy = false
            } catch let failure as JellyfinError where [404, 405].contains(failure.status) {
                let users: [PublicUser] = try await client.get("/Users/Public")
                profiles = users.map { PickableProfile(user: $0, needs: $0.hasPassword == false ? nil : "password") }
                legacy = true
            }
        } catch { self.error = error.localizedDescription }
    }

    private func switchTo(_ profile: PickableProfile) {
        guard !working, let client = session.client else { return }
        working = true
        error = nil
        let password = secret
        Task { @MainActor in
            defer { working = false }
            do {
                let result: AuthResult
                if legacy {
                    result = try await client.post("/Users/AuthenticateByName", body: ["Username": profile.user.name ?? "", "Pw": password])
                } else {
                    var body: [String: Any] = ["UserId": profile.id]
                    if profile.needs != nil { body["Pw"] = password }
                    result = try await client.post("/AIOStreams/Token", body: body)
                }
                secret = ""
                prefs.resetForProfile()
                session.signIn(result)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
