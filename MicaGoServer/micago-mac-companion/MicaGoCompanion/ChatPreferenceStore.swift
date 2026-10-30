import SwiftUI

struct ChatPreference: Codable {
    var chatGuid: String
    var hidden: Bool
    var revision: Int64
}

struct ChatPreferencesResponse: Codable {
    var serverId: String
    var revision: Int64
    var data: [ChatPreference]
}

struct ChatPreferenceChange: Codable {
    var chatGuid: String
    var hidden: Bool
    var baseRevision: Int64
}

struct ChatPreferenceMutation: Codable {
    var serverId: String
    var mutationId: String
    var changes: [ChatPreferenceChange]
}

@MainActor
final class ChatPreferenceStore: ObservableObject {
    private struct State: Codable {
        var serverId: String?
        var rows: [String: ChatPreference] = [:]
        var queue: [ChatPreferenceMutation] = []
        var conflicts: [ChatPreferenceMutation] = []
    }
    private let key = "chat.preferences.v1"
    private let defaults: UserDefaults
    private var state: State
    @Published private(set) var hidden: Set<String> = []
    @Published private(set) var errorKey: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var busy = false
    var hasConflicts: Bool { !state.conflicts.isEmpty }
    var pending: Bool { !state.queue.isEmpty }
    var ready: Bool { state.serverId != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
        publish()
    }

    private func publish() {
        defaults.set(try? JSONEncoder().encode(state), forKey: key)
        var result = Set(state.rows.values.filter(\.hidden).map(\.chatGuid))
        for change in state.queue.flatMap(\.changes) {
            if change.hidden { result.insert(change.chatGuid) }
            else { result.remove(change.chatGuid) }
        }
        hidden = result
    }

    func sync(client: APIClient) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; publish() }
        do {
            let snapshot = try await client.chatPreferences()
            if let old = state.serverId, old != snapshot.serverId {
                defaults.set(try JSONEncoder().encode(state), forKey: key + "." + old)
                if let saved = defaults.data(forKey: key + "." + snapshot.serverId) {
                    state = try JSONDecoder().decode(State.self, from: saved)
                } else { state = State() }
            }
            state.serverId = snapshot.serverId
            state.rows = Dictionary(uniqueKeysWithValues: snapshot.data.map { ($0.chatGuid, $0) })
            while let mutation = state.queue.first {
                do {
                    let reply = try await client.patchChatPreferences(mutation)
                    state.queue.removeFirst()
                    for row in reply.data {
                        if (state.rows[row.chatGuid]?.revision ?? 0) <= row.revision {
                            state.rows[row.chatGuid] = row
                        }
                        let old = mutation.changes.first { $0.chatGuid == row.chatGuid }?.baseRevision
                        for i in state.queue.indices {
                            for j in state.queue[i].changes.indices {
                                if state.queue[i].changes[j].chatGuid == row.chatGuid,
                                   state.queue[i].changes[j].baseRevision == old {
                                    state.queue[i].changes[j].baseRevision = row.revision
                                }
                            }
                        }
                    }
                } catch APIError.status(409, _) {
                    let fresh = try await client.chatPreferences()
                    guard fresh.serverId == state.serverId else { throw APIError.status(409) }
                    state.conflicts.append(state.queue.removeFirst())
                    state.rows = Dictionary(uniqueKeysWithValues: fresh.data.map { ($0.chatGuid, $0) })
                }
                publish()
            }
            errorKey = hasConflicts ? "prefs.conflict" : nil
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch let error as URLError where [
            .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .networkConnectionLost, .timedOut,
        ].contains(error.code) {
            errorKey = "prefs.offline"
            errorMessage = nil
        } catch {
            errorKey = nil
            errorMessage = error.localizedDescription
        }
    }

    func setHidden(_ guid: String, hidden: Bool, client: APIClient?) async {
        guard !busy, let server = state.serverId else { return }
        state.queue.append(ChatPreferenceMutation(serverId: server, mutationId: UUID().uuidString,
            changes: [ChatPreferenceChange(chatGuid: guid, hidden: hidden, baseRevision: state.rows[guid]?.revision ?? 0)]))
        publish()
        if let client { await sync(client: client) }
        else { errorKey = "prefs.offline"; errorMessage = nil }
    }

    func resolve(useMine: Bool, client: APIClient?) async {
        guard !busy else { return }
        if useMine, let server = state.serverId {
            var desired: [String: Bool] = [:]
            for change in state.conflicts.flatMap(\.changes) { desired[change.chatGuid] = change.hidden }
            for (guid, hidden) in desired {
                state.queue.append(ChatPreferenceMutation(serverId: server, mutationId: UUID().uuidString,
                    changes: [ChatPreferenceChange(chatGuid: guid, hidden: hidden, baseRevision: state.rows[guid]?.revision ?? 0)]))
            }
        }
        state.conflicts.removeAll()
        errorKey = nil
        errorMessage = nil
        publish()
        if let client { await sync(client: client) }
    }
}
