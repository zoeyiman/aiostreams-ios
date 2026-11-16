import Foundation
import Security
import SwiftUI

/// The server this Apple TV signed in to, kept across launches; the token stays in the Keychain.
@MainActor
final class Session: ObservableObject {
    enum Stage: Equatable {
        case needsServer
        case needsSignIn
        case signedIn
    }

    @Published private(set) var stage: Stage = .needsServer
    @Published private(set) var serverName: String?
    /// A plain Jellyfin server rather than AIOStreams, as the web app tells: its libraries sort and
    /// filter as asked, where an AIOStreams catalog keeps its own order.
    @Published private(set) var isStock = false
    @Published private(set) var userName: String?
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var profileID: UUID?
    private var serverKindKnown = false

    struct Profile: Codable, Identifiable {
        let id: UUID
        let address: URL
        let serverName: String?
        let userID: String
        let userName: String?
        let isStock: Bool
        let serverKindKnown: Bool

        var label: String {
            let server = serverName ?? address.host ?? address.absoluteString
            let name = userName.map { "\($0) · \(server)" } ?? server
            return serverKindKnown ? "\(name) · \(isStock ? L("Jellyfin") : L("AIOStreams"))" : name
        }

        var tokenKey: String { "profile.\(id.uuidString).token" }
    }
    /// The signed-in viewer opened the profile picker.
    @Published private(set) var asking = false
    private(set) var client: JellyfinClient?
    private(set) var userId: String?

    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: Keys.profiles),
           let saved = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = saved
        }
        if let active = defaults.string(forKey: Keys.activeProfile),
           let profile = profiles.first(where: { $0.id.uuidString == active }),
           let token = Keychain.read(profile.tokenKey) {
            activate(profile, token: token)
            return
        }

        guard let saved = defaults.string(forKey: Keys.server), let base = URL(string: saved) else { return }
        serverName = defaults.string(forKey: Keys.serverName)
        client = Self.makeClient(base)
        stage = .needsSignIn
        // Move an existing install's single login into the profile picker.
        if let token = Keychain.read(Keys.token), let user = defaults.string(forKey: Keys.userId) {
            saveProfile(address: base, user: user, name: defaults.string(forKey: Keys.userName), token: token)
            if let profile = profiles.first(where: { $0.id == profileID }), Keychain.read(profile.tokenKey) == token {
                Keychain.delete(Keys.token)
                defaults.removeObject(forKey: Keys.userId)
                defaults.removeObject(forKey: Keys.userName)
                let legacy = defaults.stringArray(forKey: "live.recent") ?? []
                defaults.set(legacy, forKey: RecentChannels.key(for: profile.id))
                defaults.removeObject(forKey: "live.recent")
            }
        }
    }

    private static func makeClient(_ base: URL) -> JellyfinClient {
        JellyfinClient(base: base, token: nil, deviceId: AppInfo.deviceId, deviceName: AppInfo.deviceName)
    }

    /// Reads whether the server is AIOStreams or plain Jellyfin.
    func readServerKind() async {
        guard !serverKindKnown, let client, let id = profileID else { return }
        if let info: PublicSystemInfo = try? await client.get("/System/Info/Public"),
           !Task.isCancelled, profileID == id, self.client?.token == client.token {
            isStock = info.aiostreams == nil
            serverKindKnown = true
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                let previous = profiles[index]
                profiles[index] = Profile(id: id, address: previous.address, serverName: previous.serverName,
                                          userID: previous.userID, userName: previous.userName, isStock: isStock,
                                          serverKindKnown: true)
                persistProfiles()
            }
        }
    }

    /// Checks the address answers as this kind of server before keeping it.
    func connect(to address: String) async throws {
        guard let base = JellyfinClient.normalize(address) else {
            throw JellyfinError(status: 0, message: L("That is not a valid address."))
        }
        let client = Self.makeClient(base)
        let info: PublicSystemInfo = try await client.get("/System/Info/Public")
        self.client = client
        isStock = info.aiostreams == nil
        serverKindKnown = true
        serverName = info.serverName
        defaults.set(base.absoluteString, forKey: Keys.server)
        defaults.set(info.serverName, forKey: Keys.serverName)
        stage = .needsSignIn
        AppLog.info("session", "connected to \(base.host ?? "?") (\(info.serverName ?? "unnamed"))")
    }

    func signIn(_ result: AuthResult) {
        guard let client else { return }
        saveProfile(address: client.base, user: result.user.id, name: result.user.name, token: result.accessToken)
    }

    private func saveProfile(address: URL, user: String, name: String?, token: String) {
        let id = profiles.first { $0.address == address && $0.userID == user }?.id ?? UUID()
        let profile = Profile(id: id, address: address, serverName: serverName, userID: user,
                              userName: name, isStock: isStock, serverKindKnown: serverKindKnown)
        Keychain.write(profile.tokenKey, token)
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persistProfiles()
        activate(profile, token: token)
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Keys.profiles) }
    }

    private func activate(_ profile: Profile, token: String) {
        var next = Self.makeClient(profile.address)
        next.token = token
        client = next
        userId = profile.userID
        userName = profile.userName
        serverName = profile.serverName
        isStock = profile.isStock
        serverKindKnown = profile.serverKindKnown
        defaults.set(profile.id.uuidString, forKey: Keys.activeProfile)
        defaults.set(profile.address.absoluteString, forKey: Keys.server)
        defaults.set(profile.serverName, forKey: Keys.serverName)
        profileID = profile.id
        stage = .signedIn
        asking = false
    }

    /// Reuse only a token issued for this user on the connected server.
    func resumeProfile(userID: String) -> Bool {
        guard let address = client?.base,
              let profile = profiles.first(where: { $0.address == address && $0.userID == userID }),
              let token = Keychain.read(profile.tokenKey) else { return false }
        activate(profile, token: token)
        return true
    }

    func switchProfile(_ profile: Profile) {
        if let token = Keychain.read(profile.tokenKey) {
            activate(profile, token: token)
        } else {
            addProfile(onSameServer: false)
            client = Self.makeClient(profile.address)
            defaults.set(profile.address.absoluteString, forKey: Keys.server)
            defaults.set(profile.serverName, forKey: Keys.serverName)
            serverName = profile.serverName
            isStock = profile.isStock
            serverKindKnown = profile.serverKindKnown
            stage = .needsSignIn
        }
    }

    func addProfile(onSameServer: Bool) {
        profileID = nil
        defaults.removeObject(forKey: Keys.activeProfile)
        userId = nil
        userName = nil
        asking = false
        if onSameServer, let client {
            self.client = Self.makeClient(client.base)
            stage = .needsSignIn
        } else {
            client = nil
            serverName = nil
            serverKindKnown = false
            isStock = false
            defaults.removeObject(forKey: Keys.server)
            defaults.removeObject(forKey: Keys.serverName)
            stage = .needsServer
        }
    }

    func signOut() {
        if let client, client.token != nil {
            Task { await client.fire("/Sessions/Logout", body: [:]) }
        }
        if let profile = profiles.first(where: { $0.id == profileID }) {
            Keychain.delete(profile.tokenKey)
            profiles.removeAll { $0.id == profile.id }
            persistProfiles()
        }
        addProfile(onSameServer: client != nil)
    }

    /// Whoever was watching carries on, without signing in again.
    func carryOn() { asking = false }

    func chooseProfile() {
        guard stage == .signedIn else { return }
        asking = true
    }

    func forgetServer() {
        addProfile(onSameServer: false)
    }

    /// The token expired or was revoked on the configure page.
    func expired(_ rejected: JellyfinClient) {
        guard client?.base == rejected.base, client?.token == rejected.token else { return }
        AppLog.warn("session", "the server no longer accepts this sign-in")
        signOut()
    }

    private enum Keys {
        static let server = "server.base"
        static let serverName = "server.name"
        static let userId = "user.id"
        static let userName = "user.name"
        static let token = "user.token"
        static let profiles = "account.profiles"
        static let activeProfile = "account.activeProfile"
    }
}

/// Generic password items for this app alone.
enum Keychain {
    private static let service = "io.github.aiostreams-ios.tv"

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var item = query(key)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}
