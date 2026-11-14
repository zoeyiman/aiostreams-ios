import SwiftUI

// Live TV, after the web app's (app/live-tv, features/live-tv/live-tv.ts): the server's channels by
// group, as a list with what's on now and next, or as a guide of the coming hours. Choosing a
// channel plays it live.

/// Channels played on this Apple TV, newest first, which the Recent group lists.
enum RecentChannels {
    private static let limit = 30

    private static func key(client: JellyfinClient, userId: String) -> String {
        let identity = Data((client.base.absoluteString + "|" + userId).utf8).base64EncodedString()
        return "live.recent.v2." + identity
    }

    static func ids(client: JellyfinClient, userId: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(client: client, userId: userId)) ?? []
    }

    static func note(_ id: String, client: JellyfinClient, userId: String, defaults: UserDefaults = .standard) {
        let existing = ids(client: client, userId: userId, defaults: defaults)
        defaults.set(updated(id, existing: existing), forKey: key(client: client, userId: userId))
        NotificationCenter.default.post(name: .liveHistoryChanged, object: nil)
    }

    static func updated(_ id: String, existing: [String]) -> [String] {
        var seen = Set<String>()
        return Array(([id] + existing).filter { seen.insert($0).inserted }.prefix(limit))
    }
}

struct LiveTVView: View {
    let view: Item

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var groups: [ChannelGroup] = [ChannelGroup(id: ChannelGroup.all, name: "All channels")]
    @State private var group = UserDefaults.standard.string(forKey: "live.group") ?? ChannelGroup.all
    @State private var guide = UserDefaults.standard.string(forKey: "live.view") == "guide"
    @State private var channels: [Item] = []
    @State private var recentChannels: [Item] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var loading = false
    @State private var channelError: String?
    @State private var pageGeneration = UUID()
    /// Programmes by channel, from the half hour before now to six hours on.
    @State private var schedules: [String: [Item]] = [:]
    @State private var now = Date()
    @State private var selectedChannel: Item?
    @State private var fullscreen = false
    @State private var choosingGroup = false
    @State private var favoriteChannels = Set<String>()
    @State private var favoriteBusy = false
    @State private var favoriteError: String?
    @StateObject private var preview = LivePreview()

    private static let page = 100

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: Theme.px(24)) {
                controls
                if guide {
                    ScrollView {
                        GuideView(channels: channels, schedules: schedules, window: window, now: now, play: play)
                        if !loaded { ProgressView() }
                        if let error = channelError {
                            ErrorText(text: error)
                            Button("Retry channels") { Task { await more() } }.buttonStyle(SecondaryPillStyle())
                        }
                        if channels.count < total {
                            Button("More channels") { Task { await more() } }.buttonStyle(SecondaryPillStyle())
                        }
                    }
                    .scrollClipDisabled()
                } else {
                    HStack(alignment: .top, spacing: Theme.px(32)) {
                        ScrollView {
                            LazyVStack(spacing: Theme.px(8)) {
                                if !loaded { ProgressView().padding(Theme.px(32)) }
                                if let error = channelError {
                                    ErrorText(text: error)
                                    Button("Retry channels") { Task { await more() } }.buttonStyle(SecondaryPillStyle())
                                }
                                if loaded && channels.isEmpty && channelError == nil {
                                    Text("No channels in this group.").foregroundStyle(Theme.gray400).focusable()
                                }
                                ForEach(channels) { channel in
                                    LiveChannelTile(channel: channel, slots: slots(channel), now: now,
                                                    selected: selectedChannel?.id == channel.id) { play(channel) }
                                        .onAppear { if channel.id == channels.last?.id { Task { await more() } } }
                                }
                            }
                            .padding(Theme.px(8))
                        }
                        .scrollClipDisabled()
                        .frame(width: max(Theme.px(260), geometry.size.width * 0.42))
                        .focusSection()
                        ScrollView { programmePanel }
                            .scrollClipDisabled()
                            .frame(maxWidth: .infinity)
                            .focusSection()
                    }
                }
            }
            .padding(.horizontal, Theme.px(24))
            .padding(.top, Theme.px(28))
            .padding(.bottom, Theme.px(24))
        }
        .background(Theme.background)
        .fullScreenCover(isPresented: $choosingGroup) { groupPicker }
        .fullScreenCover(isPresented: $fullscreen, onDismiss: {
            preview.surfaceID = UUID()
            preview.model?.liftSubtitles(0)
        }) {
            if let model = preview.model {
                PlayerChrome(model: model, close: { fullscreen = false }, playNext: { _ in }, finding: nil,
                             stopPlayback: { preview.stop(); fullscreen = false })
                    .environmentObject(session).environmentObject(prefs)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveHistoryChanged)) { _ in
            Task { await loadGroups(); if group == ChannelGroup.recent { await reload() } }
        }
        .task { await loadGroups() }
        .task(id: "\(group)-\(guide)") { await reload() }
        .task(id: selectedChannel?.id) {
            if let channel = selectedChannel { await preview.play(channel, session: session, prefs: prefs) }
        }
        .onDisappear { if !fullscreen && !choosingGroup { preview.stop() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
    }

    @ViewBuilder private var programmePanel: some View {
        VStack(alignment: .leading, spacing: Theme.px(20)) {
            if let channel = selectedChannel {
                if let model = preview.model, !fullscreen {
                    LivePreviewSurface(model: model)
                        .id(preview.surfaceID)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.px(16)).fill(.white.opacity(0.04))
                        if preview.loading { ProgressView() }
                        else { Image(systemName: "play.tv").font(.system(size: Theme.px(48))).foregroundStyle(Theme.gray400) }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                }
                if let error = preview.error {
                    ErrorText(text: error)
                    Button("Retry channel") { Task { await preview.play(channel, session: session, prefs: prefs) } }
                        .buttonStyle(SecondaryPillStyle())
                }
                Text([channel.channelNumber, channel.name].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.font(Theme.base, .semibold)).foregroundStyle(Theme.gray400)
                if let current = slots(channel).now {
                    Text(current.name).font(Theme.font(Theme.xl2, .bold))
                    if let start = current.start, let end = current.end {
                        Text("\(prefs.time(start)) – \(prefs.time(end)) · \(max(0, Int(ceil(end.timeIntervalSince(now) / 60))))m left")
                            .font(Theme.font(Theme.base)).foregroundStyle(Theme.gray300)
                        ProgressView(value: airedShare(from: start, to: end, now: now)).tint(.white)
                    }
                    if let current = (schedules[channel.id] ?? []).first(where: { ($0.starts ?? .distantFuture) <= now && ($0.ends ?? .distantPast) > now }),
                       let overview = current.overview {
                        Text(overview).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray300)
                    } else if let overview = channel.currentProgram?.overview {
                        Text(overview).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray300)
                    }
                }
                HStack(spacing: Theme.px(16)) {
                    if let model = preview.model {
                        LivePreviewActions(model: model, expand: { fullscreen = true }, retry: {
                            Task { await preview.play(channel, session: session, prefs: prefs, force: true) }
                        })
                    }
                    Button { Task { await toggleFavorite(channel) } } label: {
                        Image(systemName: favoriteChannels.contains(channel.id) ? "heart.fill" : "heart")
                    }
                    .buttonStyle(CircleIconStyle(active: favoriteChannels.contains(channel.id)))
                    .disabled(favoriteBusy)
                    .accessibilityLabel(favoriteChannels.contains(channel.id) ? "Remove channel favorite" : "Favorite channel")
                }
                if let error = favoriteError { ErrorText(text: error) }
                let later = (schedules[channel.id] ?? []).filter { ($0.starts ?? .distantPast) > now }
                if !later.isEmpty {
                    Text("LATER").font(Theme.font(Theme.sm, .semibold)).foregroundStyle(Theme.gray400)
                    ForEach(later.prefix(4)) { programme in
                        HStack(alignment: .top, spacing: Theme.px(16)) {
                            Text(programme.starts.map(prefs.time) ?? "").foregroundStyle(Theme.gray400)
                            Text(programme.name ?? "Programme")
                        }
                        .font(Theme.font(Theme.base))
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: Theme.px(16)).fill(.white.opacity(0.04))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay { Label("Select a channel to watch", systemImage: "play.tv").foregroundStyle(Theme.gray400) }
            }
        }
        .padding(Theme.px(8))
    }

    @MainActor private func toggleFavorite(_ channel: Item) async {
        guard !favoriteBusy, let client = session.client, let userId = session.userId else { return }
        favoriteBusy = true
        favoriteError = nil
        defer { favoriteBusy = false }
        let wasFavorite = favoriteChannels.contains(channel.id)
        do {
            try await client.call(wasFavorite ? "DELETE" : "POST", "/UserFavoriteItems/\(channel.id)", ["userId": userId])
            if wasFavorite { favoriteChannels.remove(channel.id) } else { favoriteChannels.insert(channel.id) }
            await loadGroups()
            if group == ChannelGroup.favourites { await reload() }
        } catch { favoriteError = error.localizedDescription }
    }

    // MARK: Groups and view

    private var controls: some View {
        HStack(spacing: Theme.px(16)) {
            Button("All channels") { choose(ChannelGroup.all) }
                .buttonStyle(SoftPillStyle(selected: group == ChannelGroup.all))
            Button { choosingGroup = true } label: {
                Label(groups.first { $0.id == group }?.name ?? "Channel group", systemImage: "chevron.down")
            }
            .buttonStyle(SecondaryPillStyle())
            if !recentChannels.isEmpty {
                Button("Recently Watched") { choose(ChannelGroup.recent) }
                    .buttonStyle(SoftPillStyle(selected: group == ChannelGroup.recent))
            }
            Spacer()
            Picker("View", selection: Binding(get: { guide }, set: { setGuide($0) })) {
                Text("Guide").tag(true)
                Text("Channels").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: Theme.px(230))
        }
        .focusSection()
    }

    private var groupPicker: some View {
        VStack(alignment: .leading, spacing: Theme.px(24)) {
            Text("Channel groups").font(Theme.font(Theme.xl3, .bold))
            ScrollView {
                LazyVStack(spacing: Theme.px(12)) {
                    ForEach(groups) { item in
                        Button {
                            choose(item.id)
                            choosingGroup = false
                        } label: {
                            HStack {
                                Text(item.name)
                                Spacer()
                                if item.id == group { Image(systemName: "checkmark") }
                            }
                            .padding(Theme.px(20))
                        }
                        .buttonStyle(RowStyle())
                    }
                }
            }
            Button("Cancel") { choosingGroup = false }.buttonStyle(SecondaryPillStyle())
        }
        .padding(Theme.px(56))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onExitCommand { choosingGroup = false }
    }

    private func setGuide(_ on: Bool) {
        guide = on
        UserDefaults.standard.set(on ? "guide" : "list", forKey: "live.view")
    }

    private func choose(_ id: String) {
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
        if (await favourites?.totalRecordCount ?? 0) > 0 { list.append(ChannelGroup(id: ChannelGroup.favourites, name: "Favourites")) }
        if !RecentChannels.ids(client: client, userId: userId).isEmpty { list.append(ChannelGroup(id: ChannelGroup.recent, name: "Recently Watched")) }
        list.append(ChannelGroup(id: ChannelGroup.all, name: "All channels"))
        list += (await genres?.items ?? []).map { ChannelGroup(id: $0.id, name: $0.name ?? "") }
        let ids = RecentChannels.ids(client: client, userId: userId)
        if ids.isEmpty {
            recentChannels = []
        } else {
            let result: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": ids.joined(separator: ",")])
            let byId = Dictionary((result?.items ?? []).map { ($0.id, $0) }) { first, _ in first }
            recentChannels = ids.compactMap { byId[$0] }.filter(\.isChannel)
        }
        groups = list
        // A group that's gone, such as Favourites emptied elsewhere, goes back to all channels.
        if !list.contains(where: { $0.id == group }) { choose(ChannelGroup.all) }
    }

    // MARK: Channels

    private func reload() async {
        pageGeneration = UUID()
        loading = false
        channelError = nil
        channels = []
        total = 0
        schedules = [:]
        loaded = false
        await more()
    }

    private func more() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        if loaded && channels.count >= total && channelError == nil { return }
        let generation = pageGeneration
        let asked = group
        loading = true
        channelError = nil
        defer { if generation == pageGeneration { loading = false } }
        do {
            let found: [Item]
            let count: Int
            if asked == ChannelGroup.recent {
                let ids = RecentChannels.ids(client: client, userId: userId)
                if ids.isEmpty { found = [] }
                else {
                    let result: ItemsResult = try await client.get("/Items", ["userId": userId, "Ids": ids.joined(separator: ",")])
                    let byId = Dictionary((result.items ?? []).map { ($0.id, $0) }) { first, _ in first }
                    found = ids.compactMap { byId[$0] }.filter(\.isChannel)
                }
                count = found.count
            } else {
                let result: ItemsResult = try await client.get("/LiveTv/Channels", [
                    "userId": userId, "StartIndex": String(channels.count), "Limit": String(Self.page),
                    "IsFavorite": asked == ChannelGroup.favourites ? "true" : nil,
                    "GenreIds": [ChannelGroup.favourites, ChannelGroup.all].contains(asked) ? nil : asked,
                    "AddCurrentProgram": "true", "EnableTotalRecordCount": "true",
                ])
                found = result.items ?? []
                count = found.isEmpty ? channels.count : (result.totalRecordCount ?? (found.count < Self.page ? channels.count + found.count : Int.max))
            }
            try Task.checkCancellation()
            guard generation == pageGeneration, asked == group else { return }
            for channel in found where channel.userData?.isFavorite == true { favoriteChannels.insert(channel.id) }
            let known = Set(channels.map(\.id))
            channels += found.filter { !known.contains($0.id) }
            total = count
            loaded = true
            await loadSchedules(for: found.map(\.id), generation: generation)
        } catch is CancellationError {
        } catch {
            guard generation == pageGeneration else { return }
            channelError = error.localizedDescription
            loaded = true
        }
    }

    /// The window the guide shows, from the last half hour.
    private var window: (start: Date, end: Date) {
        let step = 30.0 * 60
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / step).rounded(.down) * step)
        return (start, start.addingTimeInterval(6 * 3600))
    }

    private func loadSchedules(for ids: [String], generation: UUID) async {
        guard !ids.isEmpty, let client = session.client, let userId = session.userId else { return }
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
            guard generation == pageGeneration, !Task.isCancelled else { return }
            for programme in result?.items ?? [] {
                guard let channel = programme.channelId else { continue }
                schedules[channel, default: []].append(programme)
            }
        }
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

    private func play(_ channel: Item) {
        if guide { setGuide(false) }
        if selectedChannel?.id == channel.id {
            if let model = preview.model, model.failure == nil && !model.finished { fullscreen = true }
            else { Task { await preview.play(channel, session: session, prefs: prefs, force: true) } }
        } else { selectedChannel = channel }
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
                    if case .success(let image) = phase { image.resizable().scaledToFit() }
                }
                .padding(Theme.px(6))
            } else {
                Text(channel.channelNumber ?? String((channel.name ?? "?").prefix(2)))
                    .font(Theme.font(Theme.base, .semibold))
                    .foregroundStyle(Theme.gray300)
            }
        }
    }
}

// MARK: - Guide

/// Channels down the side and the coming hours across, each programme as wide as it lasts. The
/// channels stay put while the hours scroll; both scroll up and down together.
private struct GuideView: View {
    @EnvironmentObject private var prefs: Preferences
    let channels: [Item]
    let schedules: [String: [Item]]
    let window: (start: Date, end: Date)
    let now: Date
    let play: (Item) -> Void

    @FocusState private var focused: String?

    private static let minute = Theme.px(4)
    private static let rowHeight = Theme.px(56)
    private static let gap = Theme.px(4)
    private static let channelWidth = Theme.px(200)

    private var width: CGFloat { CGFloat(window.end.timeIntervalSince(window.start) / 60) * Self.minute }

    private func x(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(window.start), 0), window.end.timeIntervalSince(window.start)) / 60) * Self.minute
    }

    /// The programme with focus, for the details above the grid.
    private var focusedProgramme: Item? {
        guard let focused else { return nil }
        for list in schedules.values { if let match = list.first(where: { $0.id == focused }) { return match } }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(16)) {
            details
                .frame(height: Theme.px(72), alignment: .topLeading)
                .pagePadding()
            HStack(alignment: .top, spacing: Self.gap) {
                VStack(spacing: Self.gap) {
                    Color.clear.frame(height: Theme.px(28))
                    ForEach(channels) { channel in
                        Button { play(channel) } label: {
                            HStack(spacing: Theme.px(10)) {
                                ChannelLogo(channel: channel)
                                    .frame(width: Theme.px(64), height: Theme.px(36))
                                Text(channel.channelNumber ?? channel.name ?? "")
                                    .font(Theme.font(Theme.sm, .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.px(10))
                            .frame(width: Self.channelWidth, height: Self.rowHeight)
                        }
                        .buttonStyle(RowStyle(radius: Theme.px(8)))
                    }
                }
                .padding(.leading, pageMargin + pageInset)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: Self.gap) {
                        timeline
                        ForEach(channels) { channel in
                            row(channel)
                        }
                    }
                    .padding(.trailing, pageMargin)
                    .padding(.vertical, Theme.px(4))
                }
                .scrollClipDisabled()
            }
        }
        .focusSection()
    }

    @ViewBuilder private var details: some View {
        if let programme = focusedProgramme {
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                HStack(spacing: Theme.px(10)) {
                    Text(programme.name ?? "").font(Theme.font(Theme.lg, .semibold)).lineLimit(1)
                    if let start = programme.starts, let end = programme.ends {
                        Text("\(prefs.time(start)) – \(prefs.time(end))")
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
            Text("Choose a programme on now to watch its channel.")
                .font(Theme.font(Theme.sm))
                .foregroundStyle(Theme.gray400)
        }
    }

    /// The half hours across the top, with a line where now is.
    private var timeline: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<12, id: \.self) { index in
                let time = window.start.addingTimeInterval(Double(index) * 1800)
                Text(prefs.time(time))
                    .font(Theme.font(Theme.xs, .medium))
                    .foregroundStyle(Theme.gray400)
                    .offset(x: x(time) + Theme.px(4))
            }
            Rectangle().fill(Theme.ring).frame(width: Theme.px(2), height: Theme.px(28)).offset(x: x(now))
        }
        .frame(width: width, height: Theme.px(28), alignment: .topLeading)
    }

    private struct Segment {
        var id: String
        var width: CGFloat
        var programme: Item?
    }

    /// The row laid out from the left: each programme as wide as its slot, with a space where
    /// the guide has nothing. Laid out rather than offset, so focus moves follow what's drawn.
    private func segments(_ programmes: [Item]) -> [Segment] {
        var list: [Segment] = []
        var cursor: CGFloat = 0
        for programme in programmes {
            let start = max(x(programme.starts ?? window.start), cursor)
            let end = x(programme.ends ?? window.end)
            guard end - start >= Theme.px(4) else { continue }
            if start > cursor { list.append(Segment(id: "gap-\(programme.id)", width: start - cursor)) }
            list.append(Segment(id: programme.id, width: end - start, programme: programme))
            cursor = end
        }
        return list
    }

    private func cell(_ programme: Item, channel: Item, width: CGFloat) -> some View {
        let airing = (programme.starts ?? .distantFuture) <= now && now < (programme.ends ?? .distantPast)
        return Button {
            if airing { play(channel) }
        } label: {
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                Text(programme.name ?? "").font(Theme.font(Theme.sm, .medium)).lineLimit(1)
                if let begins = programme.starts {
                    Text(prefs.time(begins)).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
                }
            }
            .padding(.horizontal, Theme.px(10))
            .frame(width: max(width - Self.gap, Theme.px(4)), height: Self.rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                    .fill(airing ? Theme.brand500.opacity(0.25) : Color.white.opacity(0.05))
            )
        }
        .buttonStyle(RowStyle(radius: Theme.px(8)))
        .focused($focused, equals: programme.id)
        .padding(.trailing, Self.gap)
    }

    private func row(_ channel: Item) -> some View {
        let programmes = (schedules[channel.id] ?? []).filter {
            ($0.ends ?? .distantPast) > window.start && ($0.starts ?? .distantFuture) < window.end
        }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                .fill(.white.opacity(0.02))
                .frame(width: width, height: Self.rowHeight)
            if programmes.isEmpty {
                Text("No guide for this channel")
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray500)
                    .padding(.horizontal, Theme.px(12))
                    .frame(height: Self.rowHeight)
            }
            HStack(spacing: 0) {
                ForEach(segments(programmes), id: \.id) { segment in
                    if let programme = segment.programme {
                        cell(programme, channel: channel, width: segment.width)
                    } else {
                        Color.clear.frame(width: segment.width, height: Self.rowHeight)
                    }
                }
            }
        }
        .frame(width: width, height: Self.rowHeight, alignment: .topLeading)
    }
}

/// Each player request owns a gate; failed loads and later resumes cannot add extra entries.
struct ChannelHistoryGate {
    private var recorded = false

    mutating func shouldRecord(requested: Bool, playing: Bool, ready: Bool, stopped: Bool,
                               channel: Bool, trailer: Bool) -> Bool {
        guard requested, playing, ready, !stopped, channel, !trailer, !recorded else { return false }
        recorded = true
        return true
    }
}
