import AVFoundation
import SwiftUI
import TVServices

@main
struct AIOStreamsTVApp: App {
    @StateObject private var session = Session()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        AppLog.info("app", "started \(AppInfo.version) on \(AppInfo.deviceModel) tvOS \(UIDevice.current.systemVersion)")
    }

    var body: some Scene {
        WindowGroup {
            ProfileContent()
                .id(session.profileID)
                .environmentObject(session)
                .task { await DemoMode.start(session) }
                .onOpenURL { DeepLink.open($0) }
                .onChange(of: session.profileID) { _, _ in
                    TVPictureInPicture.shared.stop()
                    TopShelfStore.save(.init(sections: []))
                    TVTopShelfContentProvider.topShelfContentDidChange()
                }
        }
    }
}

private struct ProfileContent: View {
    @EnvironmentObject private var session: Session
    @StateObject private var prefs = Preferences()
    @StateObject private var wash = ArtWash()

    var body: some View {
        Group {
            switch session.stage {
            case .needsServer: ServerView()
            case .needsSignIn: SignInView().id(session.client?.base)
            case .signedIn:
                if session.asking { SignInView() } else { MainView() }
            }
        }
        .environment(\.locale, AppLanguage.locale)
        .environment(\.layoutDirection, AppLanguage.rightToLeft ? .rightToLeft : .leftToRight)
        .environmentObject(prefs)
        .environmentObject(wash)
        .preferredColorScheme(.dark)
        .tint(Theme.ring)
    }
}

/// Saved accounts can also be reached before signing in to a new server.
private struct SavedProfiles: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        if !session.profiles.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(session.profiles) { profile in
                        Button(profile.label) { session.switchProfile(profile) }
                            .buttonStyle(SoftPillStyle(selected: profile.id == session.profileID))
                    }
                }
                .padding(Theme.px(8))
            }
            .frame(maxWidth: Theme.px(760))
            .focusSection()
        }
    }
}

/// A message under a screen, for what went wrong.
struct ErrorText: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                .multilineTextAlignment(.center)
        }
    }
}

/// The sign-in screens' backdrop: the page's black with a faint glow from the top.
struct WelcomeBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(
                colors: [Color(red: 30 / 255, green: 32 / 255, blue: 70 / 255).opacity(0.8), .clear],
                center: .top,
                startRadius: 0,
                endRadius: Theme.px(620)
            )
        }
        .ignoresSafeArea()
    }
}

struct ServerView: View {
    @EnvironmentObject private var session: Session
    @State private var address = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack(spacing: Theme.px(24)) {
                BrandLogo(height: Theme.px(64))
                Text(L("Connect to your server"))
                    .font(Theme.font(Theme.xl2, .semibold))
                    .foregroundStyle(Theme.gray200)
                Text(L("Use the address from your configure page: Save & Install → Jellyfin apps → Connect. With a share alias it's short, like your-instance/jellyfin/u/alias."))
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray400)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Theme.px(560))
                TextField(L("Server address"), text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(Theme.font(Theme.base))
                    .frame(maxWidth: Theme.px(560))
                    .onSubmit(connect)
                Button(working ? L("Connecting…") : L("Connect"), action: connect)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
                if !working { SavedProfiles() }
                ErrorText(text: error)
            }
            .foregroundStyle(.white)
        }
    }

    private func connect() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await session.connect(to: address)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// "Who's watching?", as the web app asks on a TV: the configuration's users, then a password
/// where one is set; or Quick Connect, or a name typed in.
struct SignInView: View {
    private enum Mode: Equatable {
        case pick
        case password(PublicUser)
        case manual
        case quickConnect
    }

    @EnvironmentObject private var session: Session
    @State private var mode: Mode = .pick
    @State private var users: [PublicUser] = []
    @State private var loaded = false
    @State private var quickConnectEnabled = false
    @State private var code: String?
    @State private var name = ""
    @State private var accountIdentifier = ""
    @State private var serverProfileNeeds: [String: String] = [:]

    private struct ServerProfile: Decodable {
        let user: PublicUser
        let needs: String?
    }
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var poll: Task<Void, Never>?

    var body: some View {
        ZStack {
            WelcomeBackground()
            VStack(spacing: Theme.px(28)) {
                BrandLogo(height: Theme.px(64))
                switch mode {
                case .pick: picker
                case .password(let user): passwordForm(user)
                case .manual: manualForm
                case .quickConnect: quickConnectPanel
                }
                ErrorText(text: error)
            }
            .foregroundStyle(.white)
        }
        .task { await load() }
        .onDisappear { poll?.cancel() }
        .onChange(of: mode) { _, mode in
            error = nil
            if mode == .quickConnect { startQuickConnect() } else { poll?.cancel() }
        }
        .onExitCommand(perform: exitAction)
    }

    private var exitAction: (() -> Void)? {
        if mode != .pick { return { mode = .pick } }
        if session.asking { return { session.carryOn() } }
        return nil
    }

    private var picker: some View {
        VStack(spacing: Theme.px(28)) {
            Text(users.isEmpty && loaded ? L("Sign in") : L("Who's watching?"))
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            if !users.isEmpty {
                ViewThatFits(in: .horizontal) {
                    profileAvatars
                    ScrollView(.horizontal) { profileAvatars }
                }
                .focusSection()
            } else if !loaded {
                ProgressView()
            }
            HStack(spacing: Theme.px(8)) {
                if !session.asking || users.isEmpty {
                    Button(L("Other user")) { name = ""; password = ""; mode = .manual }
                    if quickConnectEnabled { Button(L("Quick Connect")) { mode = .quickConnect } }
                }
                Button(L("Change server")) { session.forgetServer() }
            }
            .buttonStyle(SoftPillStyle())
            .padding(.top, Theme.px(8))
            .focusSection()
            if !session.asking { SavedProfiles() }
        }
        .padding(.horizontal, Theme.px(48))
    }

    private var profileAvatars: some View {
        HStack(spacing: Theme.px(40)) {
            ForEach(users) { user in
                Button {
                    selectProfile(user)
                } label: {
                    UserAvatar(user: user, url: avatarURL(user))
                }
                .buttonStyle(AvatarStyle())
                .disabled(working)
            }
        }
        .padding(Theme.px(10))
    }

    private func selectProfile(_ user: PublicUser) {
        if session.asking && user.id == session.userId {
            session.carryOn()
            return
        }
        if let needs = serverProfileNeeds[user.id] {
            password = ""
            if needs.isEmpty {
                switchServerProfile(user, secret: "")
            } else {
                mode = .password(user)
            }
            return
        }
        if session.resumeProfile(userID: user.id) { return }

        name = user.name ?? ""
        password = ""
        guard !requiresAccountIdentifier, user.enableAutoLogin ?? (user.hasPassword == false),
              !name.isEmpty, var client = session.client else {
            mode = .password(user)
            return
        }

        // An unlocked profile may support an empty password on a picker address.
        // Only the server can issue the selected user's token.
        client.token = nil
        working = true
        error = nil
        Task {
            defer { working = false }
            let result: AuthResult? = try? await client.post("/Users/AuthenticateByName", body: [
                "Username": user.name ?? "", "Pw": "",
            ])
            guard session.client?.base == client.base, session.stage != .signedIn || session.asking else { return }
            if let result, result.user.id == user.id {
                session.signIn(result)
            } else {
                mode = .password(user)
            }
        }
    }

    private func switchServerProfile(_ user: PublicUser, secret: String) {
        guard !working, session.asking, let client = session.client else { return }
        let originalProfile = session.profileID
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let result: AuthResult = try await client.post("/AIOStreams/Token", body: [
                    "UserId": user.id, "Pw": secret,
                ])
                guard session.asking, session.profileID == originalProfile,
                      session.client?.base == client.base else { return }
                guard result.user.id.lowercased() == user.id.lowercased() else {
                    error = L("The server returned a different profile.")
                    return
                }
                session.signIn(result)
            } catch {
                if session.asking && session.profileID == originalProfile {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private var requiresAccountIdentifier: Bool {
        !session.isStock && session.client?.base.path.lowercased() == "/jellyfin"
    }

    private func passwordForm(_ user: PublicUser) -> some View {
        let needs = serverProfileNeeds[user.id]
        let pinOnly = needs == "pin"
        let needsAccount = needs == nil && requiresAccountIdentifier
        return VStack(spacing: Theme.px(20)) {
            UserAvatar(user: user, url: avatarURL(user))
            Text(pinOnly ? L("PIN for %@", user.name ?? L("this user")) : L("Password for %@", user.name ?? L("this user")))
                .font(Theme.font(Theme.xl, .semibold))
                .foregroundStyle(Theme.gray200)
            if needs == nil || needs == "password-pin" {
                Text(L("If the user has a PIN, add it after the password with a /, like password/1234."))
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray400)
            }
            if needsAccount {
                TextField(L("Configuration UUID or alias"), text: $accountIdentifier)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: Theme.px(440))
            }
            SecureField(pinOnly ? L("PIN") : L("Password"), text: $password)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
                .onSubmit(signIn)
            HStack(spacing: Theme.px(12)) {
                Button(working ? L("Signing in…") : L("Sign in"), action: signIn)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working || (needsAccount && accountIdentifier.trimmingCharacters(in: .whitespaces).isEmpty))
                Button(L("Back")) { mode = .pick }.buttonStyle(SecondaryPillStyle())
            }
        }
    }

    private var manualForm: some View {
        VStack(spacing: Theme.px(20)) {
            Text(L("Sign in"))
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            TextField(L("Name"), text: $name)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
            SecureField(L("Password, and /PIN if the user has one"), text: $password)
                .font(Theme.font(Theme.base))
                .frame(maxWidth: Theme.px(440))
                .onSubmit(signIn)
            HStack(spacing: Theme.px(12)) {
                Button(working ? L("Signing in…") : L("Sign in"), action: signIn)
                    .buttonStyle(PrimaryPillStyle())
                    .disabled(working || name.isEmpty)
                Button(L("Back")) { mode = .pick }.buttonStyle(SecondaryPillStyle())
            }
        }
    }

    private var quickConnectPanel: some View {
        VStack(spacing: Theme.px(20)) {
            Text(L("Quick Connect"))
                .font(Theme.font(Theme.xl2, .semibold))
                .foregroundStyle(Theme.gray200)
            if let code {
                Text(code)
                    .font(Theme.font(64, .bold))
                    .monospacedDigit()
                    .kerning(Theme.px(8))
            } else {
                ProgressView().frame(height: Theme.px(80))
            }
            Text(L("On your configure page, open Save & Install → Jellyfin apps → Connect, type this code into the Quick Connect box and approve it."))
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Theme.px(560))
            Button(L("Back")) { mode = .pick }.buttonStyle(SoftPillStyle())
        }
    }

    private func avatarURL(_ user: PublicUser) -> URL? {
        guard let client = session.client, let tag = user.primaryImageTag else { return nil }
        return client.url("/Users/\(user.id)/Images/Primary", ["tag": tag, "fillHeight": "240", "quality": "90"])
    }

    private func load() async {
        guard let client = session.client else { return }
        var publicClient = client
        publicClient.token = nil
        async let publicUsers: [PublicUser]? = try? publicClient.get("/Users/Public")
        async let serverUsers: [PublicUser]? = session.asking && client.token != nil
            ? try? client.get("/Users") : nil
        async let quickConnect: Bool? = try? publicClient.get("/QuickConnect/Enabled")
        async let switchable: [ServerProfile]? = session.asking && client.token != nil && !session.isStock
            ? try? client.get("/AIOStreams/Users") : nil
        let (listed, authenticated, quick, shared) = await (publicUsers, serverUsers, quickConnect, switchable)
        guard !Task.isCancelled else { return }
        var seen = Set<String>()
        let visibleUsers = (authenticated ?? []).filter {
            $0.policy?.isHidden != true || $0.id == session.userId
        }
        if let shared {
            users = shared.map(\.user).filter { seen.insert($0.id).inserted }
            serverProfileNeeds = Dictionary(shared.map { ($0.user.id, $0.needs ?? "") }, uniquingKeysWith: { first, _ in first })
        } else {
            users = (visibleUsers + (listed ?? [])).filter { seen.insert($0.id).inserted }
        }
        quickConnectEnabled = quick ?? false
        loaded = true
        if session.asking && users.isEmpty, let id = session.userId, let name = session.userName {
            users = [PublicUser(id: id, name: name)]
            error = L("The server did not return any other profiles.")
        }
        if users.isEmpty && !session.asking { mode = quickConnectEnabled ? .quickConnect : .manual }
    }

    private func startQuickConnect() {
        guard let client = session.client else { return }
        poll?.cancel()
        code = nil
        poll = Task {
            do {
                let started: QuickConnectState = try await client.post("/QuickConnect/Initiate")
                code = started.code
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4))
                    let state: QuickConnectState = try await client.get("/QuickConnect/Connect", ["Secret": started.secret])
                    if state.authenticated == true {
                        let result: AuthResult = try await client.post(
                            "/Users/AuthenticateWithQuickConnect",
                            body: ["Secret": started.secret]
                        )
                        guard !Task.isCancelled, session.client?.base == client.base else { return }
                        session.signIn(result)
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                // A code lasts a few minutes; a new one replaces it.
                if !Task.isCancelled {
                    AppLog.info("signin", "quick connect: \(error.localizedDescription)")
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled, mode == .quickConnect { startQuickConnect() }
                }
            }
        }
    }

    private func signIn() {
        if case .password(let user) = mode, serverProfileNeeds[user.id] != nil {
            switchServerProfile(user, secret: password)
            return
        }
        guard let client = session.client, !working, !name.isEmpty else { return }
        let account = accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let pickedUser: Bool
        if case .password = mode { pickedUser = true } else { pickedUser = false }
        guard !pickedUser || !requiresAccountIdentifier || !account.isEmpty else { return }
        let username = pickedUser && requiresAccountIdentifier ? "\(account)/\(name)" : name
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                let result: AuthResult = try await client.post(
                    "/Users/AuthenticateByName",
                    body: ["Username": username, "Pw": password]
                )
                guard session.client?.base == client.base, session.stage != .signedIn || session.asking else { return }
                poll?.cancel()
                session.signIn(result)
            } catch let failure as JellyfinError where failure.status == 401 {
                error = L("That password doesn't match.")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A user's picture, or their initial on a colour of their own, with their name under it.
struct UserAvatar: View {
    let user: PublicUser
    let url: URL?

    var body: some View {
        VStack(spacing: Theme.px(12)) {
            ZStack {
                Circle().fill(Theme.brand500.opacity(0.38))
                Text(String((user.name ?? "?").prefix(1)).uppercased())
                    .font(Theme.font(44, .bold))
                    .foregroundStyle(.white)
                if let url {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fill) }
                    }
                }
            }
            .frame(width: Theme.px(112), height: Theme.px(112))
            .clipShape(Circle())
            Text(user.name ?? L("User"))
                .font(Theme.font(15))
                .foregroundStyle(Theme.gray200)
        }
    }
}

/// The ring goes round the picture alone, not its name.
private struct AvatarStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AvatarFocus(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct AvatarFocus<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let pressed: Bool

        var body: some View {
            label
                .brightness(focused ? 0.10 : 0)
                .scaleEffect(focused ? 1.05 : 1)
                .opacity(pressed ? 0.85 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// A link into the app (`aiostreams://item/<id>`, `aiostreams://play/<id>`), from Top Shelf. Kept until
/// the signed-in pages take it, as one can arrive before they're shown.
enum DeepLink {
    static let opened = Notification.Name("aiostreams.deepLink")
    private(set) static var pending: URL?

    static func open(_ url: URL) {
        pending = url
        NotificationCenter.default.post(name: opened, object: nil)
    }

    /// The link waiting, once: whether to play, and the title's id.
    static func take() -> (play: Bool, id: String)? {
        guard let url = pending, url.scheme == "aiostreams", let host = url.host(),
              ["item", "play"].contains(host), let id = url.pathComponents.dropFirst().first else { return nil }
        pending = nil
        return (host == "play", id)
    }
}
