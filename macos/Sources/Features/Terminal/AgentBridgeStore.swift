#if os(macOS)
import Combine
import Foundation

struct AgentBridgeState: Codable, Equatable, Identifiable {
    var sessionID: String
    var sessionFile: String?
    var ghosttySurfaceID: String?
    var pid: Int
    var cwd: String
    var todoID: String?
    var status: String
    var message: String?
    var updatedAt: String

    var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionFile = "session_file"
        case ghosttySurfaceID = "ghostty_surface_id"
        case pid
        case cwd
        case todoID = "todo_id"
        case status
        case message
        case updatedAt = "updated_at"
    }
}

enum AgentBridgeWorkspaceStatus: Equatable {
    case working(Character)
    case attention
    case none
}

@MainActor
final class AgentBridgeStore: ObservableObject {
    static let shared = AgentBridgeStore()

    @Published private(set) var statesBySessionID: [String: AgentBridgeState] = [:]

    static var bridgeDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/ghostty/sessions", isDirectory: true)
    }

    private static let workingIndicator: Character = "⠿"
    private let staleStateAge: TimeInterval = 5 * 60
    private let refreshInterval: TimeInterval = 2
    private var refreshCancellable: AnyCancellable?

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let dateFormatter: ISO8601DateFormatter = {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return dateFormatter
    }()

    private init() {
        reload()
        refreshCancellable = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reload()
            }
    }

    func reload() {
        let staleCutoffDate = Date().addingTimeInterval(-staleStateAge)
        var freshStatesBySessionID: [String: AgentBridgeState] = [:]

        for fileURL in bridgeFileURLs() where fileURL.pathExtension == "json" {
            guard let state = state(from: fileURL),
                  let updatedAt = dateFormatter.date(from: state.updatedAt),
                  updatedAt >= staleCutoffDate
            else { continue }

            freshStatesBySessionID[state.sessionID] = state
        }

        if statesBySessionID != freshStatesBySessionID {
            statesBySessionID = freshStatesBySessionID
        }
    }

    func state(forSessionID sessionID: String?) -> AgentBridgeState? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return statesBySessionID[sessionID]
    }

    func state(forTodoID todoID: String) -> AgentBridgeState? {
        statesBySessionID.values.first { state in
            guard let bridgeTodoID = state.todoID else { return false }
            return bridgeTodoID == todoID ||
                bridgeTodoID == "TODO-\(todoID)" ||
                "TODO-\(bridgeTodoID)" == todoID
        }
    }

    func states(forSurfaceID surfaceID: String?) -> [AgentBridgeState] {
        guard let surfaceID, !surfaceID.isEmpty else { return [] }
        return statesBySessionID.values.filter { $0.ghosttySurfaceID == surfaceID }
    }

    func workspaceStatus(forSurfaceIDs surfaceIDs: [String]) -> AgentBridgeWorkspaceStatus {
        let surfaceIDSet = Set(surfaceIDs)
        guard !surfaceIDSet.isEmpty else { return .none }

        return workspaceStatus(for: statesBySessionID.values.filter { state in
            guard let ghosttySurfaceID = state.ghosttySurfaceID else { return false }
            return surfaceIDSet.contains(ghosttySurfaceID)
        })
    }

    func workspaceStatus(for states: [AgentBridgeState]) -> AgentBridgeWorkspaceStatus {
        if states.contains(where: { $0.status == "working" }) {
            return .working(Self.workingIndicator)
        }

        if states.contains(where: { $0.status == "done" }) {
            return .attention
        }

        return .none
    }

    func acknowledgeAttention(forSurfaceID surfaceID: String) {
        var updatedStatesBySessionID = statesBySessionID
        var didUpdateState = false

        for fileURL in bridgeFileURLs() where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  var state = try? decoder.decode(AgentBridgeState.self, from: data),
                  state.ghosttySurfaceID == surfaceID,
                  state.status == "done"
            else { continue }

            state.status = "idle"
            state.message = nil
            state.updatedAt = dateFormatter.string(from: Date())

            guard let updatedData = try? encoder.encode(state) else { continue }
            try? updatedData.write(to: fileURL, options: .atomic)
            updatedStatesBySessionID[state.sessionID] = state
            didUpdateState = true
        }

        if didUpdateState {
            statesBySessionID = updatedStatesBySessionID
        }
    }

    private func bridgeFileURLs() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: Self.bridgeDirectoryURL,
            includingPropertiesForKeys: nil)) ?? []
    }

    private func state(from fileURL: URL) -> AgentBridgeState? {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? decoder.decode(AgentBridgeState.self, from: data)
        else { return nil }

        return state
    }
}
#endif
