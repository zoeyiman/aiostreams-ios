import SwiftUI

/// Default destinations plus optional pages the user can enable.
enum Place: String, CaseIterable, Identifiable {
    case home, live, favourites, search, settings, discover, playlists, calendar, activity

    var id: String { rawValue }

    static let main: [Place] = [.home, .live, .favourites, .search, .settings]

    static let optional: [Place] = [.discover, .playlists, .calendar, .activity]
    static let sidebar: [Place] = [.home, .live, .favourites, .search] + optional + [.settings]
    static let startPages: [Place] = [.home, .live, .favourites] + optional
    var canHide: Bool { self != .home && self != .settings }

    static func visible(overrides: [String: Bool]) -> [Place] {
        sidebar.filter { !$0.canHide || (overrides[$0.rawValue] ?? main.contains($0)) }
    }

    var name: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .search: return "Search"
        case .favourites: return "My Library"
        case .settings: return "Settings"
        case .discover: return "Discover"
        case .playlists: return "Playlists"
        case .calendar: return "Calendar"
        case .activity: return "Activity"
        }
    }

    /// SF Symbols standing in for the web app's BoxIcons.
    var icon: String {
        switch self {
        case .home: return "house"
        case .live: return "play.tv"
        case .search: return "magnifyingglass"
        case .favourites: return "rectangle.stack"
        case .settings: return "gearshape"
        case .discover: return "safari"
        case .playlists: return "list.bullet.rectangle"
        case .calendar: return "calendar"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

private enum SidebarFocus: Hashable {
    case destination(Place)
    case toggle
}

/// Persistent expanded/icon-only navigation with a separate focus identity for its toggle.
struct MainView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    /// Opens on a supported start page; legacy destinations fall back to Home.
    @State private var place: Place = Place(rawValue: UserDefaults.standard.string(forKey: "app.startPage") ?? "") ?? .home
    /// The server's Live TV library, when available.
    @State private var liveView: Item?
    @State private var paths: [Place: NavigationPath] = [:]
    @FocusState private var railFocus: SidebarFocus?
    /// What a card's menu asked to play, from any page.
    @State private var choice: VersionChoice?
    @Namespace private var railScope
    /// The whole screen, rail and page, which focus is re-picked within after a rail choice.
    @Namespace private var shellScope
    @Environment(\.resetFocus) private var resetFocus
    /// Briefly true after a rail choice, so focus leaves the rail for the page; and at launch,
    /// so the app opens with the rail shut and focus on Home.
    @State private var railLocked = true
    /// A first Back on Home, which a second within a couple of seconds follows to leave.
    @State private var exitArmed = false
    @State private var exitHint: Task<Void, Never>?

    @AppStorage("tv.sidebar.expanded") private var expanded = false
    private var open: Bool { expanded }
    private var visiblePlaces: [Place] { Place.visible(overrides: prefs.sidebarVisibility) }
    private var railWidth: CGFloat { Theme.px(open ? 256 : 80) }

    /// Where the shade stops being solid: past the open rail's widest name.
    private static let solidShade = Theme.px(12 + 232 + 32)

    private func path(_ place: Place) -> Binding<NavigationPath> {
        Binding(get: { paths[place] ?? NavigationPath() }, set: { paths[place] = $0 })
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.background.ignoresSafeArea()

            NavigationStack(path: path(place)) {
                page(place)
                    .routes()
                    .toolbar(.hidden, for: .navigationBar)
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
            .padding(.leading, railWidth)

            // The rail's own column, which rows scrolled under it disappear beneath.
            Theme.background
                .frame(width: railWidth)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // The open rail's shade over the page beside it: solid under the names, so the page's
            // own text can't show through them, then fading out across the page.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: Self.solidShade / Theme.px(576)),
                    .init(color: .black.opacity(0.7), location: 0.75),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Theme.px(576))
            .opacity(open ? 1 : 0)
            .allowsHitTesting(false)
            .ignoresSafeArea()

            rail
        }
        .ignoresSafeArea()
        .focusScope(shellScope)
        .font(Theme.font(Theme.base))
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: open)
        .playFlow($choice) { NotificationCenter.default.post(name: .watchStateChanged, object: nil) }
        .alert("Couldn’t update saved titles", isPresented: Binding(
            get: { session.saveError != nil }, set: { if !$0 { session.saveError = nil } }
        )) { Button("OK") { session.saveError = nil } } message: {
            Text(session.saveError ?? "")
        }
        .task { await findLiveTV() }
        .task {
            if let client = session.client, let userId = session.userId {
                prefs.loadSidebar(client: client, userId: userId)
            }
            if !visiblePlaces.contains(place) { place = .home }
            await startOnPage()
            guard let client = session.client, let userId = session.userId else { return }
            await prefs.load(client: client, userId: userId)
            await openDemoScreen()
        }
        // Back from another place's first page goes Home; from Home, it leaves the app.
        .onExitCommand(perform: exitAction)
        .overlay(alignment: .bottom) {
            if exitArmed {
                Text("Press Back again to leave")
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
        .onChange(of: visiblePlaces) { _, visible in
            if !visible.contains(place) { place = .home }
            if case .destination(let focused) = railFocus, !visible.contains(focused) {
                railFocus = .destination(place)
            }
        }
    }

    @ViewBuilder private func page(_ place: Place) -> some View {
        switch place {
        case .home: HomeView()
        case .live:
            if let liveView { LiveTVView(view: liveView) } else {
                ComingSoonView(title: "Live TV", text: "No channels are available on this server.")
            }
        case .search: SearchView()
        case .favourites: FavouritesView()
        case .settings: SettingsView()
        case .discover: LibrariesView()
        case .playlists: PlaylistsView()
        case .calendar: CalendarView()
        case .activity: ActivityView()
        }
    }

    /// The destination stays available even when this server has no channels.
    private func findLiveTV() async {
        guard let client = session.client, let userId = session.userId else { return }
        let views: ItemsResult? = try? await client.get("/UserViews", ["userId": userId])
        liveView = views?.items?.first { $0.collectionType == "livetv" }
    }

    /// Screenshot mode only: opens the screen the launch asked for.
    private func openDemoScreen() async {
        guard DemoMode.active else { return }
        let item = await DemoMode.item(session)
        switch DemoMode.screen {
        case "rail":
            try? await Task.sleep(for: .seconds(1))
            railFocus = .destination(.home)
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
    private func startOnPage() async {
        for wait in [300, 700, 1000] {
            try? await Task.sleep(for: .milliseconds(wait))
            if railFocus != nil { resetFocus(in: shellScope) }
        }
        railLocked = false
    }

    /// Moves focus from the rail to the page, retaining the chosen sidebar width.
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

    private var rail: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                BrandLogo(height: Theme.px(32))
                    .frame(width: Theme.px(24), height: Theme.px(32))
                    .padding(.horizontal, Theme.px(14))
                    .padding(.bottom, Theme.px(24))
                Button {
                    expanded.toggle()
                } label: {
                    Label(open ? "Collapse sidebar" : "Expand sidebar", systemImage: "sidebar.left")
                        .labelStyle(.iconOnly)
                        .frame(width: Theme.px(56), height: Theme.px(48))
                }
                .buttonStyle(RailButtonStyle())
                .focused($railFocus, equals: .toggle)
                .focusRing(railFocus == .toggle, radius: Theme.px(12))
                .accessibilityLabel(open ? "Collapse sidebar" : "Expand sidebar")
                ForEach(visiblePlaces) { entry($0) }
            }
            .padding(.horizontal, Theme.px(12))
            .padding(.vertical, Theme.px(32))
            // The rail keeps its icons' width when it opens: its names are drawn beside the buttons,
            // not in them, so the page stays to their right and a press right reaches it.
            .frame(width: railWidth, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(width: railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .focusSection()
        .focusScope(railScope)
        .onMoveCommand { direction in
            if direction == .right { leaveRail() }
            if direction == .left { expanded = false }
        }
        // Off for a moment after a choice, which hands focus to the page; and in screenshot mode,
        // where the page takes focus as it does on a real Apple TV.
        .disabled(DemoMode.keepsRailShut || railLocked)
    }

    /// What Back does on a place's first page: from another place, go Home; on Home, leave,
    /// with "Prevent accidental exit" on only at a second press, as the Android TV app asks.
    private var exitAction: (() -> Void)? {
        // Let NavigationStack pop detail screens before the shell handles Back.
        guard paths[place]?.isEmpty ?? true else { return nil }
        if railFocus == nil { return { railFocus = .destination(place); exitArmed = false } }
        if expanded { return { expanded = false } }
        if place != .home { return { place = .home; railFocus = .destination(.home) } }
        // Left to the system, Back leaves the app.
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

    private func entry(_ item: Place) -> some View {
        let current = item == place
        return Button {
            if item == place {
                // Choosing the place you're on goes back to its first page.
                paths[item] = NavigationPath()
            }
            place = item
            leaveRail()
        } label: {
            RailEntry(item: item, current: current, open: open)
        }
        .buttonStyle(RailButtonStyle())
        .accessibilityLabel(item.name)
        .accessibilityValue(current ? "Selected" : "")
        .focused($railFocus, equals: .destination(item))
        .prefersDefaultFocus(current, in: railScope)
    }


}

private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// One rail button: 48 px high and fully rounded, the current place filled, the focused one ringed.
private struct RailEntry: View {
    @Environment(\.isFocused) private var focused
    let item: Place
    let current: Bool
    let open: Bool

    /// An open entry's pill, icon and name together, as the web app's open rail draws it.
    private static let openWidth = Theme.px(232)
    private static let width = Theme.px(56)

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: item.icon)
                .font(.system(size: Theme.px(20), weight: current ? .semibold : .regular))
            .frame(width: Theme.px(24))
        }
        .padding(.horizontal, Theme.px(16))
        .frame(width: Self.width, height: Theme.px(48), alignment: .leading)
        .foregroundStyle(current || focused ? Color.white : Theme.gray400)
        // Drawn past the button's own frame, which focus moves are measured from. The page you're
        // on is filled; where the remote is gets the app's focus ring, so the two never look alike.
        .background(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(current ? 0.12 : 0))
                .frame(width: open ? Self.openWidth : Self.width, height: Theme.px(48))
                .overlay {
                    if focused {
                        Capsule()
                            .strokeBorder(Theme.ring, lineWidth: Theme.ringWidth)
                            .padding(-(Theme.ringWidth + Theme.ringOffset))
                    }
                }
        }
        .overlay(alignment: .leading) {
            if open {
                Text(item.name)
                    .font(Theme.font(Theme.base, .medium))
                    .foregroundStyle(current || focused ? Color.white : Theme.gray400)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: Theme.px(56))
                    .transition(.opacity)
            }
        }
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
        }
        .padding(Theme.px(40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keeps focus somewhere on a page with nothing to press.
        .focusable()
    }
}
