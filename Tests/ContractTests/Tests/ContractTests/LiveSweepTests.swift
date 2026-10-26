import Foundation
import PurlayContract
import PurlayKit
import Testing

@Suite("against a real server: every read the contract lists", .needsServer, .serialized)
struct LiveSweepTests {
    /// Each GET route that answers JSON, called with what the demo's world can give it, and its answer read as the contract's
    /// own type for it and written back. A route that needs input this does not have is named, not skipped in silence.
    @Test("every GET route answers in the shape the contract promises")
    func everyRead() async throws {
        let world = try World.load()
        let persona = try world.persona("dogancan")
        let client = world.client(as: persona)

        let messageID = try await firstMessageID(world, client)
        let values: [String: String] = [
            "workspaceId": world.workspaceID, "channelId": world.channels["api"] ?? "", "messageId": messageID,
            "userId": persona.userID,
        ]

        var read: [String] = []
        var needsInput: [String] = []
        var failures: [String] = []
        for endpoint in Endpoints.all where endpoint.method == "GET" {
            guard
                case .schema(let name)? = endpoint.responses.sorted(by: { $0.key < $1.key }).first(where: {
                    $0.key == 200
                })?.value
            else { continue }
            let names = endpoint.path.split(separator: "/").filter { $0.hasPrefix(":") }.map { String($0.dropFirst()) }
            guard names.allSatisfy({ values[$0] != nil && values[$0] != "" }) else {
                needsInput.append("\(endpoint.id) (\(names.joined(separator: ", ")))")
                continue
            }
            let path = Dictionary(uniqueKeysWithValues: names.map { ($0, values[$0] ?? "") })
            do {
                let response = try await client.sendForResponse(endpoint, path: path)
                guard let roundTrip = ContractRegistry.roundTrips[name] else {
                    failures.append("\(endpoint.id): no type for \(name)")
                    continue
                }
                _ = try roundTrip(response.body)
                read.append(endpoint.id)
            } catch let error as APIError where [400, 403, 404].contains(error.status) {
                // The route wants a query or a state this world is not in: said, and not a failure of the contract.
                needsInput.append("\(endpoint.id) → \(error.status) \(error.code.rawValue)")
            } catch {
                failures.append("\(endpoint.id): \(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(read.count >= 10, "only \(read.count) reads were covered: \(read)")
        Issue.record(
            Comment(
                rawValue:
                    "covered \(read.count): \(read.sorted().joined(separator: ", "))\nnot covered \(needsInput.count): \(needsInput.sorted().joined(separator: "; "))"
            ),
            severity: .warning)
    }

    @Test("the reads that need a query answer in the shape too: search, the inbox and the saved lists")
    func readsWithQueries() async throws {
        let world = try World.load()
        let api = PurlayAPI(client: world.client(as: try world.persona("dogancan")))
        let workspace = try #require(Uuid(world.workspaceID))
        let channelText = try #require(world.channels["api"])
        let channel = try #require(Uuid(channelText))

        _ = try await api.listNotifications(query: NotificationQuery(workspaceId: workspace))
        _ = try await api.listNotifications(
            query: NotificationQuery(limit: 1, unreadOnly: true, workspaceId: workspace))
        for state in [SavedState.inProgress, .archived, .completed] {
            _ = try await api.listSaved(workspaceId: world.workspaceID, query: SavedQuery(state: state))
        }
        let found = try await api.searchMessages(workspaceId: world.workspaceID, query: SearchQuery(q: "the"))
        #expect(found.data.allSatisfy { MessageID.isShape($0.id.value) })
        let scoped = try await api.searchMessages(
            workspaceId: world.workspaceID, query: SearchQuery(channelId: channel, limit: 5, q: "the"))
        #expect(scoped.data.count <= 5)
    }

    private func firstMessageID(_ world: World, _ client: APIClient) async throws -> String {
        let channelID = try #require(world.channels["api"])
        let page = try await PurlayAPI(client: client).listMessages(channelId: channelID, query: PageQuery(limit: 5))
        return try #require(page.data.first).id.value
    }
}
