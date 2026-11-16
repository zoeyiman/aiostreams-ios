import SwiftUI

/// The places the rail leads to, in the web app's order (components/layout.tsx).
enum Place: String, CaseIterable, Identifiable {
    case account, home, discover, live, search, favourites, playlists, together, calendar, activity, settings

    var id: String { rawValue }

    static let main: [Place] = [.home, .discover, .live, .search, .favourites, .playlists, .together, .calendar, .activity]

    static let sidebarDefault: [Place] = [.account] + main + [.settings]

    var name: String {
        switch self {
        case .account: return L("Profiles")
        case .home: return L("Home")
        case .discover: return L("Discover")
        case .live: return L("Live TV")
        case .search: return L("Search")
        case .favourites: return L("Favorites")
        case .playlists: return L("Playlists")
        case .together: return L("Watch together")
        case .calendar: return L("Calendar")
        case .activity: return L("Activity")
        case .settings: return L("Settings")
        }
    }

    /// SF Symbols standing in for the web app's BoxIcons.
    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .home: return "house"
        case .discover: return "safari"
        case .live: return "play.tv"
        case .search: return "magnifyingglass"
        case .favourites: return "heart"
        case .playlists: return "list.bullet.rectangle.portrait"
        case .together: return "person.2"
        case .calendar: return "calendar"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// The web app's TV layout with its default navigation, the docked rail: icons down the
/// side that open out with names, over a shade, while the rail has focus.
struct MainView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var place: Place = .home
    @State private var settingsReturn: Place = .home
    /// The server's Live TV library, which only a server with channels lists.
    @State private var liveView: Item?
    @State private var paths: [Place: NavigationPath] = [:]
    @FocusState private var railFocus: Place?
    /// What a card's menu asked to play, from any page.
    @State private var choice: VersionChoice?
    @Namespace private var railScope
    @Namespace private var topBarScope
    /// The whole screen, rail and page, which focus is re-picked within after a rail choice.
    @Namespace private var shellScope
    @Environment(\.resetFocus) private var resetFocus
    /// Briefly true after a rail choice, so focus leaves the rail for the page; and at launch,
    /// so the app opens with the rail shut and focus on Home.
    @State private var railLocked = true
    /// A first Back on Home, which a second within a couple of seconds follows to leave.
    @State private var exitArmed = false
    @State private var exitHint: Task<Void, Never>?

    private var open: Bool { railFocus != nil }
    private var onHome: Bool { place == .home && (paths[.home]?.isEmpty ?? true) }

    /// Where the shade stops being solid: past the open rail's widest name.
    private static let solidShade = Theme.px(12 + 232 + 32)

    private func path(_ place: Place) -> Binding<NavigationPath> {
        Binding(get: { paths[place] ?? NavigationPath() }, set: { paths[place] = $0 })
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The page colour, or the art of the title you're on (Background from artwork).
            WashBackground()

            NavigationStack(path: path(place)) {
                page(place)
                    .routes()
                    .toolbar(.hidden, for: .navigationBar)
                    .onExitCommand(perform: place == .settings ? nil : exitAction)
            }
            .id(place)
            // One area the focus can move into from the rail, wherever on the page it lands.
            .focusSection()
            // The page is where focus goes when the shell picks it again, rather than the rail.
            .prefersDefaultFocus(true, in: shellScope)
            .environment(\.openPlace, { place = $0 })
            .environment(\.openRoute, { route in
                var path = paths[place] ?? NavigationPath()
                path.append(route)
                paths[place] = path
            })
            .environment(\.playItem, { item, mode in
                Task { choice = await playChoice(for: item, session: session, mode: mode) }
            })
            .padding(.leading, Theme.railInset)
            .padding(.top, onHome ? 0 : Theme.topBarInset)
            .mask { pageEdge }

            if top {
                topTabs.onExitCommand(perform: exitAction)
            }

            // The rail's own column, which rows scrolled under it disappear beneath. Over the
            // artwork there's none, as in the web app: the icons sit on the art, and the page
            // fades out before reaching them instead (pageEdge).
            if !top && prefs.effectiveNavigationSurface == .solid
                && !onHome && !prefs.flag("artBackground", false) {
                Theme.background
                    .frame(width: Theme.px(80))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // The open rail's shade over the page beside it: solid under the names, so the page's
            // own text can't show through them, then fading out across the page.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: Self.solidShade / Theme.px(576)),
                    .init(color: .black.opacity(0.7), location: 0.75),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .start,
                endPoint: .end
            )
            .frame(width: Theme.px(576))
            .opacity(open && !top ? 1 : 0)
            .allowsHitTesting(false)
            .ignoresSafeArea()

            if !top {
                rail.onExitCommand(perform: exitAction).background(alignment: .leading) {
                    if prefs.effectiveNavigationSurface != .solid {
                        Color.clear
                            .frame(width: Theme.px(open ? 256 : 80))
                            .modifier(NavigationSurfaceStyle(surface: prefs.effectiveNavigationSurface,
                                                             shape: RoundedRectangle(cornerRadius: Theme.px(18))))
                            .allowsHitTesting(false)
                    }
                }
            }

            // What others in a watch party do, said briefly.
            PartyToasts()

            // Live TV reminders, asked over whatever page is open.
            ReminderHost { channel in
                Task { choice = await playChoice(for: channel, session: session) }
            }
        }
        .ignoresSafeArea()
        .focusScope(shellScope)
        .font(Theme.font(Theme.base))
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: open)
        .playFlow($choice, restoresPictureInPicture: true) { NotificationCenter.default.post(name: .watchStateChanged, object: nil) }
        .task { await findLiveTV() }
        .task {
            await session.readServerKind()
            guard !Task.isCancelled, let client = session.client, let userId = session.userId else { return }
            await prefs.load(client: client, userId: userId)
        }
        // Signed out, or asked who's watching: other devices can't reach this one meanwhile.
        .onDisappear { ServerEvents.shared.stop() }
        .onReceive(NotificationCenter.default.publisher(for: DeepLink.opened)) { _ in
            Task { await followLink() }
        }
        .task {
            await startOnPage()
            await followLink()
            guard let client = session.client, let userId = session.userId else { return }
            guard !Task.isCancelled else { return }
            LiveReminders.shared.load(userId: userId)
            // A watch party's titles open here as the party plays them.
            PartyFollow.shared.attach(session)
            // Other devices' remotes: open or play a title here.
            ServerEvents.shared.skipStep = Double(prefs.seekStep)
            ServerEvents.shared.pageHandler = { command in Task { await remote(command) } }
            ServerEvents.shared.start(client: client)
            await openDemoScreen()
        }
        .onChange(of: place) { previous, current in
            if current == .settings || current == .account {
                if previous != .settings && previous != .account { settingsReturn = previous }
            } else if previous != .settings && previous != .account {
                paths.removeValue(forKey: previous)
            }
        }
        .onChange(of: railFocus) { previous, focused in
            guard top, let focused else { return }
            // Like the web app's navigationBack, enter the bar at the current page.
            // A directional move within the bar can then switch pages.
            if previous == nil {
                if focused != place { railFocus = place }
                return
            }
            if Place.main.contains(focused), focused != place {
                place = focused
            }
        }
        .onChange(of: prefs.hiddenSidebarTabs) { _, hidden in
            if hidden.contains(place) { place = .home }
        }
        .overlay(alignment: .bottom) {
            if exitArmed {
                Text(L("Press Back again to leave"))
                    .font(Theme.font(Theme.base, .medium))
                    .padding(.horizontal, Theme.px(20))
                    .padding(.vertical, Theme.px(12))
                    .background(Capsule().fill(Color(white: 17 / 255).opacity(0.95)))
                    .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
                    .padding(.bottom, Theme.px(40))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: exitArmed)
    }

    /// Over the artwork, the page fades out across the rail's edge, so rows scrolled left dissolve
    /// before the icons rather than passing under them; elsewhere the rail's column covers them.
    @ViewBuilder private var pageEdge: some View {
        if prefs.flag("artBackground", false) && !top && !onHome {
            HStack(spacing: 0) {
                Color.clear.frame(width: Theme.px(40))
                LinearGradient(colors: [.clear, .black], startPoint: .start, endPoint: .end)
                    .frame(width: Theme.px(40))
                Color.black
            }
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    @ViewBuilder private func page(_ place: Place) -> some View {
        switch place {
        case .home: HomeView()
        case .discover: DiscoverView()
        case .live:
            if let liveView { LiveTVView(view: liveView) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        case .search: SearchView()
        case .favourites: FavouritesView()
        case .playlists: PlaylistsView()
        case .together: PartyView()
        case .calendar: CalendarView()
        case .activity: ActivityView()
        case .account: SignInView()
        case .settings: SettingsView(closeSettings: returnFromSettings)
        }
    }

    /// Shows Live TV in the rail when the server has it, and leaves it when the start page asked
    /// for Live TV on a server without.
    private func findLiveTV() async {
        guard let client = session.client, let userId = session.userId else { return }
        let views: ItemsResult? = try? await client.get("/UserViews", ["userId": userId])
        guard !Task.isCancelled else { return }
        liveView = views?.items?.first { $0.collectionType == "livetv" }
        if prefs.hiddenSidebarTabs.contains(place) || (liveView == nil && place == .live) { place = .home }
    }

    /// Screenshot mode only: opens the screen the launch asked for.
    private func openDemoScreen() async {
        guard DemoMode.active else { return }
        let item = await DemoMode.item(session)
        switch DemoMode.screen {
        case "rail":
            try? await Task.sleep(for: .seconds(1))
            railFocus = .home
        case "settings":
            place = .settings
        case "title", "movie":
            if let item { paths[.home] = { var path = NavigationPath(); path.append(Route.item(item)); return path }() }
        case "versions":
            if let item { choice = VersionChoice(item: item, startMs: item.resumeMs, mode: .list) }
        case "player":
            if let item { choice = VersionChoice(item: item, startMs: nil, mode: .straight) }
        default:
            break
        }
    }

    /// Keeps the rail shut while Home loads its first rows, then lets it take focus again. Should
    /// focus have landed on the rail before the page had anything to focus, it's moved over.
    /// A title another device's remote opens or plays here.
    private func remote(_ command: RemoteCommand) async {
        guard let client = session.client, let userId = session.userId else { return }
        let id: String
        switch command {
        case .show(let itemId): id = itemId
        case .play(let itemId, _, _): id = itemId
        default: return
        }
        let found: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": id, "Fields": "Overview,Genres"])
        guard let item = found?.items?.first else { return }
        if case .play(_, let startMs, _) = command {
            // A player closing for it gives way first.
            try? await Task.sleep(for: .milliseconds(800))
            choice = VersionChoice(item: item, startMs: startMs > 0 ? startMs : nil)
        } else {
            var path = paths[place] ?? NavigationPath()
            path.append(Route.item(item))
            paths[place] = path
        }
    }

    /// Opens or plays the title a link names (Top Shelf), from Home.
    private func followLink() async {
        guard let client = session.client, let userId = session.userId, let link = DeepLink.take() else { return }
        let found: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": link.id, "Fields": "Overview,Genres"])
        guard let item = found?.items?.first else { return }
        place = .home
        if link.play {
            choice = await playChoice(for: item, session: session)
        } else {
            paths[.home] = NavigationPath([Route.item(item)])
        }
    }

    private func startOnPage() async {
        for wait in [300, 700, 1000] {
            try? await Task.sleep(for: .milliseconds(wait))
            if railFocus != nil { resetFocus(in: shellScope) }
        }
        railLocked = false
    }

    /// Moves focus from the rail to the page just chosen, so the rail closes without a press right.
    /// Focus is re-picked within the whole screen, where the page is the preferred default; a scope
    /// holding only the page wouldn't take focus from the rail. The rail is off meanwhile, so it
    /// can't be picked again, and a second try covers a page still appearing.
    private func leaveRail() {
        railLocked = true
        Task {
            for wait in [100, 350] {
                try? await Task.sleep(for: .milliseconds(wait))
                guard railFocus != nil else { break }
                resetFocus(in: shellScope)
            }
            try? await Task.sleep(for: .milliseconds(300))
            railLocked = false
        }
    }

    /// Tabs across the top in place of the rail (Navigation: Top bar), as the web app's TV top bar:
    /// the places in a pill, with Settings and you at the end.
    private var top: Bool { prefs.tvNavigation == "top" }

    private var topTabs: some View {
        HStack(spacing: Theme.px(6)) {
            BrandLogo(height: Theme.px(22))
                .frame(height: Theme.px(22))
            // The places centred between the logo and Settings and you: every place named where they
            // fit, else only the one you're on, the rest by their icons.
            Spacer(minLength: Theme.px(12))
            ViewThatFits(in: .horizontal) {
                places(named: true)
                places(named: false)
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.px(12))
            HStack(spacing: Theme.px(2)) {
                tab(.settings)
                tab(.account)
            }
            .padding(Theme.px(4))
            .modifier(NavigationSurfaceStyle(surface: prefs.effectiveNavigationSurface, shape: Capsule()))
        }
        .padding(.horizontal, pageInset)
        .padding(.top, Theme.px(14))
        // Never wider than the screen, which would push every page off its edges.
        .frame(width: UIScreen.main.bounds.width, height: Theme.topBarInset, alignment: .topLeading)
        .focusSection()
        .focusScope(topBarScope)
        .disabled(DemoMode.keepsRailShut || railLocked)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func places(named: Bool) -> some View {
        HStack(spacing: Theme.px(2)) {
            ForEach(prefs.sidebarOrder.filter {
                Place.main.contains($0) && !prefs.hiddenSidebarTabs.contains($0) && ($0 != .live || liveView != nil)
            }) { tab($0, named: named) }
        }
        .padding(Theme.px(4))
        .modifier(NavigationSurfaceStyle(surface: prefs.effectiveNavigationSurface, shape: Capsule()))
        .fixedSize()
    }

    private func tab(_ item: Place, named: Bool = true) -> some View {
        Button {
            select(item)
            if item != .account { leaveRail() }
        } label: {
            TopTab(item: item, current: item == place, named: named, avatar: avatarURL)
        }
        .buttonStyle(RailButtonStyle())
        .focused($railFocus, equals: item)
        .prefersDefaultFocus(item == place, in: topBarScope)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(item == place ? .isSelected : [])
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Theme.px(4)) {
            BrandLogo(height: Theme.px(32))
                .frame(width: Theme.px(24), height: Theme.px(32))
                .padding(.horizontal, Theme.px(14))
                .padding(.bottom, Theme.px(24))
            ForEach(prefs.sidebarOrder.filter { !prefs.hiddenSidebarTabs.contains($0) && ($0 != .live || liveView != nil) }) { item in
                if item == .settings && prefs.sidebarOrder.last == .settings {
                    Spacer(minLength: 0)
                }
                entry(item)
                if item == .account && prefs.sidebarOrder.first == .account {
                    Rectangle().fill(.white.opacity(0.1)).frame(height: Theme.px(1))
                        .padding(.horizontal, Theme.px(12))
                        .padding(.vertical, Theme.px(4))
                }
            }
        }
        .padding(.horizontal, Theme.px(12))
        .padding(.vertical, Theme.px(32))
        // The rail keeps its icons' width when it opens: its names are drawn beside the buttons,
        // not in them, so the page stays to their right and a press right reaches it.
        .frame(width: Theme.px(80), alignment: .leading)
        .frame(maxHeight: .infinity)
        .focusSection()
        .focusScope(railScope)
        // Off for a moment after a choice, which hands focus to the page; and in screenshot mode,
        // where the page takes focus as it does on a real Apple TV.
        .disabled(DemoMode.keepsRailShut || railLocked)
    }

    private func returnFromSettings() {
        place = settingsReturn
        leaveRail()
    }

    /// Back first returns focus to the active tab. Only the Home tab can exit the app.
    private var exitAction: (() -> Void)? {
        guard paths[place]?.isEmpty ?? true else { return nil }
        if place != .home { return { railFocus = place } }
        if railFocus == nil { return { railFocus = place } }
        guard prefs.preventAccidentalExit, !exitArmed else { return nil }
        return {
            exitArmed = true
            exitHint?.cancel()
            exitHint = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { exitArmed = false }
            }
        }
    }

    private func select(_ item: Place) {
        if item == .account {
            session.chooseProfile()
            return
        }
        if item == place { paths[item] = NavigationPath() }
        place = item
        if !top { leaveRail() }
    }

    private func entry(_ item: Place) -> some View {
        let current = item == place
        return Button {
            select(item)
        } label: {
            RailEntry(item: item, current: current, open: open, avatar: avatarURL)
        }
        .buttonStyle(RailButtonStyle())
        .focused($railFocus, equals: item)
        .prefersDefaultFocus(current, in: railScope)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var avatarURL: URL? {
        guard let client = session.client, let userId = session.userId else { return nil }
        return client.url("/Users/\(userId)/Images/Primary", ["fillHeight": "96", "quality": "90"])
    }
}

private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Rail focus and the current page are shown with icon and label weight.
private struct RailEntry: View {
    @Environment(\.isFocused) private var focused
    let item: Place
    let current: Bool
    let open: Bool
    let avatar: URL?

    private static let width = Theme.px(56)

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if item == .account {
                    AsyncImage(url: avatar) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "person.crop.circle.fill").resizable()
                        }
                    }
                    .frame(width: Theme.px(24), height: Theme.px(24))
                    .clipShape(Circle())
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: Theme.px(20), weight: current || focused ? .semibold : .regular))
                }
            }
            .frame(width: Theme.px(24))
        }
        .padding(.horizontal, Theme.px(16))
        .frame(width: Self.width, height: Theme.px(48), alignment: .leading)
        .foregroundStyle(focused || current ? Color.white : Theme.gray400)
        .overlay(alignment: .leading) {
            if open {
                Text(item.name)
                    .font(Theme.font(Theme.base, focused || current ? .semibold : .medium))
                    .foregroundStyle(focused || current ? Color.white : Theme.gray400)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: Theme.px(56))
                    .transition(.opacity)
            }
        }
    }
}

/// One tab across the top, with brighter text and icons on the current and focused tabs.
private struct TopTab: View {
    @Environment(\.isFocused) private var focused
    let item: Place
    let current: Bool
    var named = true
    let avatar: URL?

    var body: some View {
        HStack(spacing: Theme.px(8)) {
            if item == .account {
                AsyncImage(url: avatar) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.crop.circle.fill").resizable()
                    }
                }
                .frame(width: Theme.px(22), height: Theme.px(22))
                .clipShape(Circle())
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: Theme.px(14), weight: current || focused ? .semibold : .regular))
                    .frame(width: Theme.px(18))
                if item != .settings && named {
                    Text(item.name).font(Theme.font(Theme.sm, .medium)).lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, item == .account || item == .settings || !named ? Theme.px(10) : Theme.px(12))
        .frame(height: Theme.px(36))
        .foregroundStyle(focused ? Color.black : current ? Color.white : Theme.gray400)
        .background(focused ? Color.white.opacity(0.94) : current ? Color.white.opacity(0.20) : Color.clear, in: Capsule())
    }
}

/// A place whose page comes in a later build.
struct ComingSoonView: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            Text(title).font(Theme.font(Theme.xl3, .bold))
            Text(text).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray400)
            Text(L("Coming in a later build.")).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray500)
        }
        .padding(Theme.px(40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keeps focus somewhere on a page with nothing to press.
        .focusable()
    }
}
