import XCTest
@testable import AIOStreamsTV

final class CollectionTests: XCTestCase {
    func testSidebarHasExactlyFiveDestinationsInOrder() {
        XCTAssertEqual(Place.main, [.home, .live, .favourites, .search, .settings])
        XCTAssertEqual(Place.favourites.name, "My Library")
    }

    func testOnlyOnDemandTitlesAreEligible() {
        for type in ["Movie", "Series", "Episode"] {
            XCTAssertTrue(Item(id: type, type: type).isOnDemand)
        }
        for type in ["TvChannel", "Program", "CollectionFolder", "Folder", ""] {
            XCTAssertFalse(Item(id: type, type: type).isOnDemand)
        }
    }

    func testRecommendationsCombineSavedAndViewingSignalsWithoutChannels() {
        let saved = (0..<12).map { Item(id: "saved\($0)", type: "Movie") }
        let watched = [Item(id: "live", type: "TvChannel"), Item(id: "episode", type: "Episode", seriesId: "show")]
        let seeds = TitleCollection.recommendationSeeds(saved: saved, watched: watched)
        XCTAssertEqual(seeds.count, 8)
        XCTAssertEqual(Array(seeds.prefix(3)), ["saved0", "show", "saved1"])
        XCTAssertFalse(seeds.contains("live"))
    }

    func testEpisodesOfSameShowSupplyOneSeed() {
        let seeds = TitleCollection.recommendationSeeds(saved: [], watched: [
            Item(id: "a", type: "Episode", seriesId: "show"),
            Item(id: "b", type: "Episode", seriesId: "show"),
        ])
        XCTAssertEqual(seeds, ["show"])
    }

    func testRecommendationsDeduplicateAndRankOverlappingInterests() {
        let a = Item(id: "a", type: "Movie")
        let b = Item(id: "b", type: "Series")
        XCTAssertEqual(TitleCollection.rankRecommendations([a, b, b], excluding: []).map(\.id), ["b", "a"])
    }

    func testRecommendationsExcludeSavedWatchedAndLiveItems() {
        let candidates = [Item(id: "saved", type: "Movie"), Item(id: "show", type: "Series"),
                          Item(id: "channel", type: "TvChannel"), Item(id: "programme", type: "Program"),
                          Item(id: "new", type: "Movie")]
        let history = [Item(id: "saved", type: "Movie"), Item(id: "ep", type: "Episode", seriesId: "show")]
        XCTAssertEqual(TitleCollection.rankRecommendations(candidates, excluding: history).map(\.id), ["new"])
    }

    func testRecentChannelMovesToFrontAndRemovesDuplicates() {
        XCTAssertEqual(RecentChannels.updated("b", existing: ["a", "b", "c", "a"]), ["b", "a", "c"])
    }

    func testRecentChannelsAreBounded() {
        let result = RecentChannels.updated("new", existing: (0..<40).map(String.init))
        XCTAssertEqual(result.count, 30)
        XCTAssertEqual(result.first, "new")
        XCTAssertEqual(result.last, "28")
    }

    func testChannelHistoryRequiresSuccessfulPlaybackAndRecordsOnce() {
        var gate = ChannelHistoryGate()
        XCTAssertFalse(gate.shouldRecord(requested: false, playing: true, ready: true, stopped: false, channel: true, trailer: false))
        XCTAssertFalse(gate.shouldRecord(requested: true, playing: false, ready: true, stopped: false, channel: true, trailer: false))
        XCTAssertFalse(gate.shouldRecord(requested: true, playing: true, ready: false, stopped: false, channel: true, trailer: false))
        XCTAssertFalse(gate.shouldRecord(requested: true, playing: true, ready: true, stopped: true, channel: true, trailer: false))
        XCTAssertFalse(gate.shouldRecord(requested: true, playing: true, ready: true, stopped: false, channel: false, trailer: false))
        XCTAssertFalse(gate.shouldRecord(requested: true, playing: true, ready: true, stopped: false, channel: true, trailer: true))
        XCTAssertTrue(gate.shouldRecord(requested: true, playing: true, ready: true, stopped: false, channel: true, trailer: false))
        XCTAssertFalse(gate.shouldRecord(requested: true, playing: true, ready: true, stopped: false, channel: true, trailer: false))
    }

    func testHistoryPersistsAndIsIsolatedByServerAndUser() throws {
        let suite = "ChannelHistoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = JellyfinClient(base: URL(string: "https://one.example/jellyfin")!, token: nil, deviceId: "test", deviceName: "Test")
        let b = JellyfinClient(base: URL(string: "https://two.example/jellyfin")!, token: nil, deviceId: "test", deviceName: "Test")
        RecentChannels.note("first", client: a, userId: "alice", defaults: defaults)
        RecentChannels.note("second", client: a, userId: "alice", defaults: defaults)
        RecentChannels.note("first", client: a, userId: "alice", defaults: defaults)
        let restored = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(RecentChannels.ids(client: a, userId: "alice", defaults: restored), ["first", "second"])
        XCTAssertEqual(RecentChannels.ids(client: a, userId: "bob", defaults: restored), [])
        XCTAssertEqual(RecentChannels.ids(client: b, userId: "alice", defaults: restored), [])
    }


    func testSidebarDefaultsAndOptionalPages() {
        XCTAssertEqual(Place.visible(overrides: [:]), Place.main)
        let visible = Place.visible(overrides: ["activity": true, "playlists": true, "live": false])
        XCTAssertTrue(visible.contains(.activity))
        XCTAssertTrue(visible.contains(.playlists))
        XCTAssertFalse(visible.contains(.live))
        XCTAssertFalse(visible.contains(.calendar))
    }

    func testSidebarAlwaysKeepsHomeAndSettingsAccessible() {
        let hidden = Dictionary(uniqueKeysWithValues: Place.sidebar.map { ($0.rawValue, false) })
        XCTAssertEqual(Place.visible(overrides: hidden), [.home, .settings])
    }

    func testSidebarCanEnableEveryDestinationWithoutDuplicates() {
        let enabled = Dictionary(uniqueKeysWithValues: Place.sidebar.map { ($0.rawValue, true) })
        let visible = Place.visible(overrides: enabled)
        XCTAssertEqual(visible, Place.sidebar)
        XCTAssertEqual(Set(visible).count, visible.count)
    }

}
