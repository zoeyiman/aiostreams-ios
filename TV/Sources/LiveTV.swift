import AetherEngineFeatures
import Combine
import SwiftUI

// Live TV, after the web app's (app/live-tv, features/live-tv/live-tv.ts): the server's channels by
// group, as a list with what's on now and next, or as a guide of the coming hours. Choosing a
// channel plays it live.

/// Channels played on this Apple TV, newest first, which the Recent group lists.
enum RecentChannels {
    private static let limit = 30

    static func key(for profile: UUID) -> String { "live.recent.\(profile.uuidString)" }

    static func ids(for profile: UUID?) -> [String] {
        guard let profile else { return [] }
        return UserDefaults.standard.stringArray(forKey: key(for: profile)) ?? []
    }

    static func note(_ id: String, for profile: UUID?) {
        guard let profile else { return }
        let previous = ids(for: profile)
        UserDefaults.standard.set(Array(([id] + previous.filter { $0 != id }).prefix(limit)), forKey: key(for: profile))
    }
}

struct LiveTVView: View {
    let view: Item

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var groups: [ChannelGroup] = [ChannelGroup(id: ChannelGroup.all, name: L("All channels"))]
    @State private var group = UserDefaults.standard.string(forKey: "live.group") ?? ChannelGroup.all
    @State private var guide = UserDefaults.standard.string(forKey: "live.view") == "guide"
    @State private var channels: [Item] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var loading = false
    /// Programmes by channel, from the half hour before now to six hours on.
    @State private var schedules: [String: [Item]] = [:]
    @State private var now = Date()
    @State private var choice: VersionChoice?
    @State private var selectedID: String?
    @State private var choosingGroup = false
    @State private var groupSearch = ""
    @State private var previewRequest = UUID()
    @FocusState private var focusedChannel: String?
    @State private var fullScreenPlayer = false
    @State private var favourites: [String: Bool] = [:]
    @State private var pendingFavourite: String?
    @State private var loadID = UUID()

    private static let page = 100

    private var showsGuide: Bool { guide && loaded && !channels.isEmpty }

    private var selected: Item? {
        let preferred = selectedID ?? RecentChannels.ids(for: session.profileID).first
        return channels.first { $0.id == preferred } ?? channels.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            header.zIndex(1)
            if providerGroups.isEmpty { controls.zIndex(1) }
            HStack(alignment: .top, spacing: Theme.px(14)) {
                if !providerGroups.isEmpty { groupsRail.padding(.leading, pageInset) }
                browserContent
            }
        }
        .padding(.bottom, Theme.px(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .edgeToEdge()
        .playFlow($choice, playerVisibility: { fullScreenPlayer = $0 }) { resumeBrowser() }
        .onChange(of: focusedChannel) { _, current in
            if let current, current != selectedID { tune(current) }
        }
        .task { await loadGroups() }
        .task(id: group) { await reload() }
        .task(id: window.start) { await refreshSchedules() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { now = Date() }
            }
        }
    }

    @ViewBuilder private var browserContent: some View {
        if choosingGroup {
            groupPicker
        } else if showsGuide {
            GuideView(channels: channels, schedules: schedules, window: window, now: now, play: play,
                      playFromStart: { programme in
                          choice = VersionChoice(item: programme, startMs: 0, mode: .straight)
                      }, more: { Task { await more() } })
                .id(group)
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selected {
            channelBrowser(selected)
        } else {
            Text(L("No channels in this group."))
                .foregroundStyle(Theme.gray400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
        }
    }

    private func channelBrowser(_ selected: Item) -> some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: Theme.px(22)) {
                ScrollView {
                    LazyVStack(spacing: Theme.px(5)) {
                        ForEach(channels) { channel in
                            ChannelRow(channel: channel, slots: slots(channel), now: now, selected: channel.id == selected.id) {
                                play(channel)
                            }
                            .focused($focusedChannel, equals: channel.id)
                            .accessibilityAddTraits(channel.id == selected.id ? .isSelected : [])
                            .onAppear { if channel.id == channels.last?.id { Task { await more() } } }
                        }
                    }
                    .padding(Theme.px(6))
                }
                .scrollClipDisabled(false)
                .frame(width: geometry.size.width * 0.39)
                .clipped()
                .focusSection()
                ScrollView {
                    channelDetail(selected, previewWidth: min(max(1, geometry.size.width * 0.61 - Theme.px(22)), geometry.size.height * 16 / 9))
                }
                .scrollClipDisabled(false)
                .clipped()
                .focusSection()
            }
        }
        .clipped()
        .pagePadding()
    }

    private func channelDetail(_ channel: Item, previewWidth: CGFloat) -> some View {
        let programmes = schedules[channel.id] ?? []
        let current = programmes.first { ($0.starts ?? .distantFuture) <= now && ($0.ends ?? .distantPast) > now }
        let later = programmes.filter { ($0.starts ?? .distantPast) > now }.prefix(3)
        let slot = slots(channel).now
        let favourite = favourites[channel.id] ?? (channel.userData?.isFavorite == true)
        return VStack(alignment: .leading, spacing: Theme.px(9)) {
            ZStack {
                ChannelLogo(channel: channel)
                if selectedID == channel.id && !fullScreenPlayer {
                    ChannelPreview(channel: channel).id(previewRequest)
                }
            }
            .frame(width: previewWidth, height: previewWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: Theme.px(12)))
            Text([channel.channelNumber, channel.name].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.font(Theme.sm, .semibold)).foregroundStyle(Theme.gray400)
            Text(slot?.name ?? channel.name ?? L("Live"))
                .font(Theme.font(Theme.xl, .bold)).lineLimit(2)
            if let slot {
                if let start = slot.start, let end = slot.end {
                    let minutes = max(1, Int(ceil(end.timeIntervalSince(now) / 60)))
                    Text("\(prefs.time(start)) – \(prefs.time(end)) · \(L("%ldm left", minutes))")
                        .font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray200)
                }
                ChannelProgress(slot: slot, now: now)
            }
            if let overview = current?.overview, !overview.isEmpty {
                Text(overview).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray200).lineLimit(3)
            }
            HStack(spacing: Theme.px(8)) {
                Button { play(channel) } label: { Label(L("Full screen"), systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(PrimaryPillStyle())
                Button {
                    Task { await setFavourite(!favourite, for: channel) }
                } label: {
                    Image(systemName: favourite ? "heart.fill" : "heart")
                }
                .buttonStyle(SoftPillStyle())
                .accessibilityLabel(favourite ? L("Remove from favourites") : L("Add to favourites"))
            }
            if !later.isEmpty {
                Text(L("Later")).font(Theme.font(Theme.xs, .semibold)).foregroundStyle(Theme.gray400)
                ForEach(later) { programme in
                    HStack(spacing: Theme.px(12)) {
                        if let start = programme.starts {
                            Text(prefs.time(start)).foregroundStyle(Theme.gray400)
                        }
                        Text(programme.name ?? "").lineLimit(2)
                    }
                    .font(Theme.font(Theme.sm))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.px(6))
        .padding(.horizontal, Theme.px(5))
    }

    private func setFavourite(_ favourite: Bool, for channel: Item) async {
        guard pendingFavourite == nil, let client = session.client, let userId = session.userId else { return }
        pendingFavourite = channel.id
        defer { pendingFavourite = nil }
        do {
            try await client.call(favourite ? "POST" : "DELETE", "/UserFavoriteItems/\(channel.id)", ["userId": userId])
            favourites[channel.id] = favourite
            await loadGroups()
            if group == ChannelGroup.favourites { await reload() }
        } catch {
            AppLog.warn("live", "could not update favourite: \(error.localizedDescription)")
        }
    }

    private func resumeBrowser() {
        Task {
            await loadGroups()
            if group == ChannelGroup.recent { await reload() }
        }
    }

    // MARK: Groups and view

    private var header: some View {
        HStack {
            Text(L("Live TV")).font(Theme.font(Theme.xl3, .bold))
            Spacer()
            HStack(spacing: Theme.px(4)) {
                Button(L("Guide")) { setGuide(true) }
                    .buttonStyle(SoftPillStyle(selected: guide))
                Button(L("Channels")) { setGuide(false) }
                    .buttonStyle(SoftPillStyle(selected: !guide))
            }
            .fixedSize()
            .focusSection()
        }
        .pagePadding()
        .padding(.top, pageTop)
    }

    private var providerGroups: [ChannelGroup] {
        groups.filter { ![ChannelGroup.all, ChannelGroup.favourites, ChannelGroup.recent].contains($0.id) }
    }

    private var controls: some View {
        let providers = providerGroups
        let usePicker = providers.count > 5 || providers.reduce(0, { $0 + $1.name.count }) > 65
        let visible = usePicker ? groups.filter { !providers.contains($0) } : groups
        let current = providers.first { $0.id == group }
        return ScrollView(.horizontal) {
            HStack(spacing: Theme.px(8)) {
                ForEach(visible) { item in
                    Button(item.name) {
                        choosingGroup = false
                        choose(item.id)
                    }
                    .buttonStyle(SoftPillStyle(selected: item.id == group))
                }
                if usePicker {
                    Button {
                        groupSearch = ""
                        choosingGroup.toggle()
                    } label: {
                        Label(current?.name ?? L("Groups"), systemImage: "line.3.horizontal.decrease")
                            .lineLimit(1)
                    }
                    .buttonStyle(SoftPillStyle(selected: current != nil || choosingGroup))
                }
            }
            .padding(Theme.px(6))
        }
        .scrollClipDisabled(false)
        .fixedSize(horizontal: false, vertical: true)
        .pagePadding()
        .focusSection()
    }

    private var groupsRail: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Text(L("Groups")).font(Theme.font(Theme.sm, .semibold))
                .padding(.leading, Theme.px(8))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.px(4)) {
                    ForEach(groups) { entry in
                        Button { choose(entry.id) } label: {
                            Text(entry.name)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Theme.px(9))
                                .padding(.vertical, Theme.px(8))
                        }
                        .buttonStyle(SoftPillStyle(selected: entry.id == group))
                    }
                }
            }
        }
        .frame(width: Theme.px(174), alignment: .leading)
        .focusSection()
    }

    private var groupPicker: some View {
        let search = groupSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = providerGroups.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        return VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack {
                TextField(L("Search groups"), text: $groupSearch)
                Button(L("Back")) { choosingGroup = false }
                    .buttonStyle(SoftPillStyle())
            }
            .focusSection()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.px(7)) {
                    ForEach(matches) { item in
                        Button {
                            choosingGroup = false
                            choose(item.id)
                        } label: {
                            HStack {
                                Text(item.name)
                                Spacer()
                                if item.id == group { Image(systemName: "checkmark") }
                            }
                            .padding(Theme.px(12))
                        }
                        .buttonStyle(RowStyle())
                    }
                    if matches.isEmpty {
                        Text(L("No matching groups.")).foregroundStyle(Theme.gray400)
                    }
                }
                .padding(Theme.px(6))
            }
            .scrollClipDisabled(false)
            .focusSection()
        }
        .frame(maxWidth: Theme.px(700), maxHeight: .infinity, alignment: .topLeading)
        .pagePadding()
        .onExitCommand { choosingGroup = false }
    }

    private func setGuide(_ on: Bool) {
        choosingGroup = false
        guide = on
        UserDefaults.standard.set(on ? "guide" : "channels", forKey: "live.view")
    }

    private func choose(_ id: String) {
        guard id != group else { return }
        selectedID = nil
        group = id
        UserDefaults.standard.set(id, forKey: "live.group")
    }

    /// Favourites and Recent where there are any, then all channels, then the server's genres.
    private func loadGroups() async {
        guard let client = session.client, let userId = session.userId else { return }
        async let favourites: ItemsResult? = try? client.get("/LiveTv/Channels", [
            "userId": userId, "IsFavorite": "true", "Limit": "1", "EnableTotalRecordCount": "true",
        ])
        async let genres: ItemsResult? = try? client.get("/Genres", [
            "userId": userId, "ParentId": view.id, "SortBy": "SortName",
        ])
        var list: [ChannelGroup] = []
        if (await favourites?.totalRecordCount ?? 0) > 0 { list.append(ChannelGroup(id: ChannelGroup.favourites, name: L("Favourites"))) }
        if !RecentChannels.ids(for: session.profileID).isEmpty { list.append(ChannelGroup(id: ChannelGroup.recent, name: L("Recently Watched"))) }
        list.append(ChannelGroup(id: ChannelGroup.all, name: L("All channels")))
        list += (await genres?.items ?? []).map { ChannelGroup(id: $0.id, name: $0.name ?? "") }
        guard !Task.isCancelled else { return }
        groups = list
        // A group that's gone, such as Favourites emptied elsewhere, goes back to all channels.
        if !list.contains(where: { $0.id == group }) { choose(ChannelGroup.all) }
    }

    // MARK: Channels

    private func reload() async {
        loadID = UUID()
        loading = false
        channels = []
        total = 0
        schedules = [:]
        loaded = false
        await more()
    }

    private func more() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        if loaded && channels.count >= total { return }
        loading = true
        let requestID = loadID
        defer { if requestID == loadID { loading = false } }
        let asked = group
        let found: [Item]
        let count: Int
        if group == ChannelGroup.recent {
            let ids = RecentChannels.ids(for: session.profileID)
            let result: ItemsResult? = ids.isEmpty ? nil : try? await client.get("/Items", [
                "userId": userId, "Ids": ids.joined(separator: ","),
            ])
            let byId = Dictionary((result?.items ?? []).map { ($0.id, $0) }) { first, _ in first }
            found = ids.compactMap { byId[$0] }.filter(\.isChannel)
            count = found.count
        } else {
            let result: ItemsResult? = try? await client.get("/LiveTv/Channels", [
                "userId": userId,
                "StartIndex": String(channels.count),
                "Limit": String(Self.page),
                "IsFavorite": group == ChannelGroup.favourites ? "true" : nil,
                "GenreIds": [ChannelGroup.favourites, ChannelGroup.all].contains(group) ? nil : group,
                "AddCurrentProgram": "true",
                "EnableTotalRecordCount": "true",
            ])
            found = result?.items ?? []
            count = found.isEmpty ? channels.count : result?.totalRecordCount ?? channels.count + found.count
        }
        guard !Task.isCancelled, asked == group, requestID == loadID else { return }
        total = count
        channels += found
        loaded = true
        let fetched = await loadSchedules(for: found.map(\.id))
        guard !Task.isCancelled, asked == group, requestID == loadID else { return }
        schedules.merge(fetched) { _, new in new }
    }

    /// The window the guide shows: two hours back, for programmes a channel keeps, to six on.
    private var window: (start: Date, end: Date) {
        let step = 30.0 * 60
        let halfHour = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
        let start = halfHour.addingTimeInterval(-GuideView.hoursBack * 3600)
        return (start, halfHour.addingTimeInterval(6 * 3600))
    }

    private func refreshSchedules() async {
        let requestID = loadID
        let asked = group
        let ids = channels.map(\.id)
        let fetched = await loadSchedules(for: ids)
        guard !Task.isCancelled, asked == group, requestID == loadID else { return }
        schedules.merge(fetched) { _, new in new }
    }

    private func loadSchedules(for ids: [String]) async -> [String: [Item]] {
        guard !ids.isEmpty, let client = session.client, let userId = session.userId else { return [:] }
        var loaded: [String: [Item]] = [:]
        let iso = ISO8601DateFormatter()
        let (start, end) = window
        for batch in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let result: ItemsResult? = try? await client.post("/LiveTv/Programs", body: [
                "UserId": userId,
                "ChannelIds": batch,
                "MinEndDate": iso.string(from: start),
                "MaxStartDate": iso.string(from: end),
                "SortBy": ["StartDate"],
                "Fields": ["Overview", "Genres"],
            ])
            guard !Task.isCancelled else { return [:] }
            for programme in result?.items ?? [] {
                guard let channel = programme.channelId else { continue }
                loaded[channel, default: []].append(programme)
            }
        }
        return loaded
    }

    /// What's on now and next: from the guide where it has the channel, else what the list sent.
    private func slots(_ channel: Item) -> (now: Slot?, next: Slot?) {
        let list = (schedules[channel.id] ?? []).filter { ($0.ends ?? .distantPast) > now }
        if let first = list.first {
            let current = (first.starts ?? .distantFuture) <= now ? first : nil
            let next = current == nil ? first : list.dropFirst().first
            return (current.map(Slot.init), next.map(Slot.init))
        }
        if let current = channel.currentProgram, (current.ends ?? .distantFuture) > now {
            return (Slot(name: current.name ?? "", start: current.starts, end: current.ends), nil)
        }
        return (nil, nil)
    }

    private func tune(_ id: String) {
        selectedID = id
        previewRequest = UUID()
    }

    private func play(_ channel: Item) {
        choice = VersionChoice(item: channel, startMs: nil, mode: .straight, channelLineup: channels)
    }
}

struct ChannelGroup: Identifiable, Equatable {
    static let favourites = "favourites"
    static let recent = "recent"
    static let all = "all"

    let id: String
    let name: String
}

/// A programme's name and times.
struct Slot {
    var name: String
    var start: Date?
    var end: Date?

    init(name: String, start: Date?, end: Date?) {
        self.name = name
        self.start = start
        self.end = end
    }

    init(_ programme: Item) {
        self.init(name: programme.name ?? "", start: programme.starts, end: programme.ends)
    }
}

/// A channel's logo, fitted into its box, or its number where it has none.
struct ChannelLogo: View {
    @EnvironmentObject private var session: Session
    let channel: Item

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous).fill(Theme.gray800)
            if let tag = channel.tag("Primary"), let client = session.client {
                AsyncImage(url: client.image(channel.id, .primary, tag: tag, width: 240)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(Theme.px(6))
                    } else if case .failure = phase {
                        // A logo the server lists but can't send: the number, as without one.
                        Text(channel.channelNumber ?? String((channel.name ?? "?").prefix(2)))
                            .font(Theme.font(Theme.base, .semibold))
                            .foregroundStyle(Theme.gray300)
                    }
                }
            } else {
                Text(channel.channelNumber ?? String((channel.name ?? "?").prefix(2)))
                    .font(Theme.font(Theme.base, .semibold))
                    .foregroundStyle(Theme.gray300)
            }
        }
    }
}

/// One channel in the list, with its current and next programmes.
private struct ChannelRow: View {
    @EnvironmentObject private var prefs: Preferences
    let channel: Item
    let slots: (now: Slot?, next: Slot?)
    let now: Date
    let selected: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: Theme.px(8)) {
                Text(channel.channelNumber ?? "")
                    .font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).monospacedDigit()
                    .lineLimit(1).frame(width: Theme.px(40), alignment: .trailing)
                ChannelLogo(channel: channel)
                    .frame(width: Theme.px(66), height: Theme.px(42))
                VStack(alignment: .leading, spacing: Theme.px(3)) {
                    Text(channel.name ?? "").font(Theme.font(Theme.sm, .semibold)).lineLimit(2)
                    Text(slots.now?.name ?? L("Live")).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray200).lineLimit(2)
                    if let current = slots.now { ChannelProgress(slot: current, now: now) }
                    if let next = slots.next {
                        Text(next.start.map { "\(prefs.time($0)) \(next.name)" } ?? next.name)
                            .font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.px(8))
            .padding(.vertical, Theme.px(6))
            .background(.white.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: Theme.px(10)))
        }
        .buttonStyle(RowStyle())
    }
}

private struct ChannelProgress: View {
    let slot: Slot
    let now: Date

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(.white.opacity(0.14))
                .overlay(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.8))
                        .frame(width: geometry.size.width * airedShare(from: slot.start, to: slot.end, now: now))
                }
        }
        .frame(height: Theme.px(2))
        .accessibilityHidden(true)
    }
}

private struct ChannelPreview: View {
    @EnvironmentObject private var session: Session
    let channel: Item
    @State private var engine: AetherEngine?
    @State private var ready = false
    @State private var failed = false

    var body: some View {
        Color.clear
            .overlay {
                if let engine {
                    ChannelPreviewSurface(engine: engine)
                        .opacity(ready ? 1 : 0)
                        .onReceive(engine.$hasFirstFrameReadyForDisplay) { ready = $0 }
                        .onReceive(engine.$state) { state in
                            if case .error = state { failed = true }
                        }
                }
                if failed {
                    Text(L("Preview unavailable")).font(Theme.font(Theme.sm, .semibold))
                        .padding(Theme.px(8))
                        .background(.black.opacity(0.8), in: Capsule())
                } else if !ready {
                    ProgressView()
                }
            }
            .accessibilityHidden(true)
            .task { await preview() }
            .onDisappear {
                engine?.stop()
                engine = nil
                ready = false
            }
    }

    private func preview() async {
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, let client = session.client, let userID = session.userId else { return }
        guard let info = try? await client.playbackInfo(userId: userID, itemId: channel.id),
              let first = info.mediaSources?.first else {
            if !Task.isCancelled { failed = true }
            return
        }
        guard !Task.isCancelled else { return }

        let source: MediaSource
        if let path = first.path, let scheme = URL(string: path)?.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            source = first
        } else {
            let named = try? await client.playbackInfo(userId: userID, itemId: channel.id, sourceId: first.ownId)
            source = named?.mediaSources?.first(where: { $0.ownId == first.ownId }) ?? first
        }
        guard !Task.isCancelled else { return }
        guard let url = client.streamURL(itemId: channel.id, source: source),
              let preview = try? AetherEngine() else {
            failed = true
            return
        }
        preview.volume = 0
        preview.videoGravity = .resizeAspect
        engine = preview
        var options = LoadOptions()
        options.isLive = true
        options.matchContentEnabled = false
        options.displayCriteriaOwner = .host
        options.httpHeaders = source.requiredHttpHeaders ?? [:]
        do {
            try await preview.load(url: url, startPosition: nil, options: options, audioSourceStreamIndex: nil)
            guard !Task.isCancelled else { preview.stop(); return }
            preview.play()
        } catch {
            preview.stop()
            if !Task.isCancelled {
                engine = nil
                ready = false
                failed = true
            }
        }
    }
}

private struct ChannelPreviewSurface: UIViewRepresentable {
    let engine: AetherEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        let view = AetherPlayerView()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.clipsToBounds = true
        container.addSubview(view)
        engine.bind(view: view)
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

// MARK: - Guide

/// The programme with focus, which only the details above the grid follow, so a focus move
/// redraws them alone rather than every row.
@MainActor
private final class GuideFocus: ObservableObject {
    @Published var programme: Item?
}

/// Where the grid is scrolled, which the channels down the side and the times across the top
/// follow, without the grid redrawing for it.
@MainActor
private final class GuideScroll: ObservableObject {
    @Published var offset: CGPoint = .zero
    @Published var height: CGFloat = 0
}

/// Channels down the side and the coming hours across, each programme as wide as it lasts. The
/// grid scrolls both ways and builds only the rows in sight; the channels and the times follow it.
private struct GuideView: View {
    let channels: [Item]
    let schedules: [String: [Item]]
    let window: (start: Date, end: Date)
    let now: Date
    let play: (Item) -> Void
    let playFromStart: (Item) -> Void
    /// Loads the next channels as the grid nears its last.
    let more: () -> Void

    @StateObject private var focus = GuideFocus()
    @StateObject private var scrolled = GuideScroll()
    /// Where the grid is scrolled: half an hour before now as it opens, once the window is known.
    @State private var scroll = ScrollPosition(edge: .leading)

    /// How far back the guide reaches, for catch-up; it opens at now.
    static let hoursBack: Double = 2

    static let minute = Theme.px(4)
    static let rowHeight = Theme.px(56)
    static let gap = Theme.px(4)
    static let channelWidth = Theme.px(200)
    static let timesHeight = Theme.px(28)
    /// Above the first row and below the last, for the focus ring.
    static let inset = Theme.px(6)

    static func top(_ index: Int) -> CGFloat { inset + CGFloat(index) * (rowHeight + gap) }

    private var layout: GuideLayout { GuideLayout(window: window) }

    private func openAtNow() {
        scroll.scrollTo(point: CGPoint(x: max(0, layout.x(now) - 30 * Self.minute), y: scrolled.offset.y))
    }

    /// Scrolls a channel down the side fully into sight, as the grid's rows go with it.
    private func reveal(_ index: Int) {
        let top = Self.top(index) - Self.inset, bottom = Self.top(index) + Self.rowHeight + Self.inset
        let y = scrolled.offset.y, height = scrolled.height
        if top < y {
            scroll.scrollTo(point: CGPoint(x: scrolled.offset.x, y: max(0, top)))
        } else if height > 0, bottom > y + height {
            scroll.scrollTo(point: CGPoint(x: scrolled.offset.x, y: bottom - height))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            GuideDetails(focus: focus)
                .frame(height: Theme.px(72), alignment: .topLeading)
                .pagePadding()
            HStack(spacing: Self.gap) {
                Color.clear.frame(width: Self.channelWidth, height: Self.timesHeight)
                GuideTimes(scrolled: scrolled, layout: layout, now: now)
            }
            .padding(.leading, pageInset)
            HStack(alignment: .top, spacing: Self.gap) {
                GuideChannels(scrolled: scrolled, channels: channels, play: play, reveal: reveal)
                    .frame(width: Self.channelWidth)
                    .padding(.leading, pageInset)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: Self.gap) {
                        ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                            GuideRow(channel: channel, programmes: schedules[channel.id] ?? [], layout: layout, now: now,
                                     focus: focus, play: play, playFromStart: playFromStart)
                                .onAppear { if index >= channels.count - 10 { more() } }
                        }
                    }
                    .padding(.vertical, Self.inset)
                    .padding(.trailing, pageMargin)
                }
                .scrollIndicators(.hidden)
                // Kept inside its frame: the page lets scroll views draw past theirs.
                .scrollClipDisabled(false)
                .clipped()
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGRect.self) { geometry in
                    CGRect(origin: geometry.contentOffset, size: geometry.containerSize)
                } action: { _, visible in
                    scrolled.offset = visible.origin
                    scrolled.height = visible.height
                }
                // Opens half an hour before now, with the earlier programmes a channel keeps to the left;
                // again once the window is known, as the guide loads after the grid first draws.
                .onAppear { openAtNow() }
                .onChange(of: window.start) { _, _ in openAtNow() }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .focusSection()
    }
}

/// Where a time falls across the guide.
private struct GuideLayout {
    let window: (start: Date, end: Date)

    var width: CGFloat { CGFloat(window.end.timeIntervalSince(window.start) / 60) * GuideView.minute }

    func x(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(window.start), 0), window.end.timeIntervalSince(window.start)) / 60) * GuideView.minute
    }
}

/// What the programme with focus is, above the grid.
private struct GuideDetails: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject var focus: GuideFocus

    var body: some View {
        if let programme = focus.programme {
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                HStack(spacing: Theme.px(10)) {
                    Text(programme.name ?? "").font(Theme.font(Theme.lg, .semibold)).lineLimit(1)
                    if let start = programme.starts, let end = programme.ends {
                        Text(verbatim: "\(prefs.time(start)) – \(prefs.time(end))")
                            .font(Theme.font(Theme.sm))
                            .foregroundStyle(Theme.gray400)
                    }
                    if let channel = programme.channelName {
                        Text(channel).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
                    }
                }
                if let overview = programme.overview {
                    Text(overview).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300).lineLimit(2)
                }
            }
        } else {
            Text(L("Choose a programme on now to watch its channel, or an earlier one marked ↺ to watch it from the start. Choosing one still to come reminds you as it starts."))
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
        }
    }
}

/// The half hours across the top, with a line where now is, moved along with the grid.
private struct GuideTimes: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject var scrolled: GuideScroll
    let layout: GuideLayout
    let now: Date

    var body: some View {
        let window = layout.window
        ZStack(alignment: .topLeading) {
            ForEach(0..<Int(window.end.timeIntervalSince(window.start) / 1800), id: \.self) { index in
                let time = window.start.addingTimeInterval(Double(index) * 1800)
                Text(prefs.time(time))
                    .font(Theme.font(Theme.xs, .medium))
                    .foregroundStyle(Theme.gray400)
                    .fixedSize()
                    .offset(x: layout.x(time) + Theme.px(4))
            }
            Rectangle().fill(Theme.ring).frame(width: Theme.px(2), height: GuideView.timesHeight).offset(x: layout.x(now))
        }
        .frame(width: layout.width, height: GuideView.timesHeight, alignment: .topLeading)
        .offset(x: -scrolled.offset.x)
        // Drawn over a space as wide as the screen leaves, never sizing it: the hours run far wider,
        // and as the space's own width they would push the whole page off the screen's left edge.
        .frame(width: 0, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: GuideView.timesHeight, alignment: .leading)
        .clipped()
    }
}

/// The channels down the side: only those in sight, placed where the grid's rows are.
private struct GuideChannels: View {
    @ObservedObject var scrolled: GuideScroll
    let channels: [Item]
    let play: (Item) -> Void
    let reveal: (Int) -> Void

    var body: some View {
        let step = GuideView.rowHeight + GuideView.gap
        let first = max(0, Int((scrolled.offset.y - GuideView.inset) / step))
        let count = Int(max(scrolled.height, Theme.px(600)) / step) + 2
        let last = min(channels.count, first + count)
        ZStack(alignment: .topLeading) {
            ForEach(first..<max(first, last), id: \.self) { index in
                GuideChannel(channel: channels[index]) { play(channels[index]) } focused: { reveal(index) }
                    .offset(y: GuideView.top(index) - scrolled.offset.y)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct GuideChannel: View {
    let channel: Item
    let action: () -> Void
    let focused: () -> Void

    var body: some View {
        Button(action: action) {
            Focused { isFocused in
                HStack(spacing: Theme.px(10)) {
                    ChannelLogo(channel: channel)
                        .frame(width: Theme.px(56), height: Theme.px(36))
                    VStack(alignment: .leading, spacing: Theme.px(1)) {
                        if let number = channel.channelNumber {
                            Text(number).font(Theme.font(Theme.xs, .medium)).foregroundStyle(Theme.gray400)
                        }
                        Text(channel.name ?? "").font(Theme.font(Theme.sm, .medium)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.px(10))
                .frame(width: GuideView.channelWidth, height: GuideView.rowHeight)
                .onChange(of: isFocused) { _, on in if on { focused() } }
            }
        }
        .buttonStyle(RowStyle(radius: Theme.px(8)))
    }
}

/// One channel's programmes across the guide.
private struct GuideRow: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var reminders = LiveReminders.shared
    let channel: Item
    let programmes: [Item]
    let layout: GuideLayout
    let now: Date
    let focus: GuideFocus
    let play: (Item) -> Void
    let playFromStart: (Item) -> Void

    private struct Segment {
        var id: String
        var width: CGFloat
        var programme: Item?
    }

    /// The row laid out from the left: each programme as wide as its slot, with a space where
    /// the guide has nothing. Laid out rather than offset, so focus moves follow what's drawn.
    private var segments: [Segment] {
        let window = layout.window
        var list: [Segment] = []
        var cursor: CGFloat = 0
        for programme in programmes where (programme.ends ?? .distantPast) > window.start && (programme.starts ?? .distantFuture) < window.end {
            let start = max(layout.x(programme.starts ?? window.start), cursor)
            let end = layout.x(programme.ends ?? window.end)
            guard end - start >= Theme.px(4) else { continue }
            if start > cursor { list.append(Segment(id: "gap-\(programme.id)", width: start - cursor)) }
            list.append(Segment(id: programme.id, width: end - start, programme: programme))
            cursor = end
        }
        return list
    }

    var body: some View {
        let segments = segments
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                .fill(.white.opacity(0.02))
                .frame(width: layout.width, height: GuideView.rowHeight)
            if segments.isEmpty {
                Text(L("No guide for this channel"))
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray500)
                    .padding(.horizontal, Theme.px(12))
                    .frame(height: GuideView.rowHeight)
            }
            HStack(spacing: 0) {
                ForEach(segments, id: \.id) { segment in
                    if let programme = segment.programme {
                        cell(programme, width: segment.width)
                    } else {
                        Color.clear.frame(width: segment.width, height: GuideView.rowHeight)
                    }
                }
            }
        }
        .frame(width: layout.width, height: GuideView.rowHeight, alignment: .topLeading)
    }

    private func cell(_ programme: Item, width: CGFloat) -> some View {
        let airing = (programme.starts ?? .distantFuture) <= now && now < (programme.ends ?? .distantPast)
        let ended = (programme.ends ?? .distantFuture) <= now
        let kept = ended && programme.aiostreams?.catchup == true
        let reminded = reminders.isSet(programme.id)
        return Button {
            if airing {
                play(channel)
            } else if kept {
                playFromStart(programme)
            } else if !ended {
                // One still to come: a reminder as it starts, or not.
                reminders.toggle(programme, on: channel)
            }
        } label: {
            Focused { isFocused in
                // Too short to read, a programme is only its slot; focused, its details show above the grid.
                Group {
                    if width >= Theme.px(64) {
                        VStack(alignment: .leading, spacing: Theme.px(2)) {
                            HStack(spacing: Theme.px(4)) {
                                if kept { Image(systemName: "arrow.counterclockwise").font(.system(size: Theme.px(10), weight: .semibold)) }
                                if reminded { Image(systemName: "bell.fill").font(.system(size: Theme.px(10), weight: .semibold)).accessibilityLabel(L("Reminder")) }
                                Text(programme.name ?? "").font(Theme.font(Theme.sm, .medium)).lineLimit(1)
                            }
                            .opacity(ended && !kept ? 0.45 : 1)
                            if let begins = programme.starts {
                                Text(prefs.time(begins)).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, Theme.px(10))
                    }
                }
                .frame(width: max(width - GuideView.gap, Theme.px(4)), height: GuideView.rowHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                        .fill(airing ? Theme.brand500.opacity(0.25) : Color.white.opacity(0.05))
                )
                .onChange(of: isFocused) { _, on in
                    if on {
                        focus.programme = programme
                    } else if focus.programme?.id == programme.id {
                        focus.programme = nil
                    }
                }
            }
        }
        .buttonStyle(RowStyle(radius: Theme.px(8)))
        .padding(.trailing, GuideView.gap)
    }
}
