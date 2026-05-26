#if os(macOS)
import Foundation

struct GhosttyAgentBridgeState: Codable {
    var sessionID: String
    var sessionFile: String?
    var ghosttySurfaceID: String?
    var pid: Int
    var cwd: String
    var todoID: String?
    var status: String
    var message: String?
    var updatedAt: String

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

enum GhosttyAgentBridge {
    static var bridgeDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/ghostty/sessions", isDirectory: true)
    }

    static func acknowledgeAttention(forSurfaceID surfaceID: String) {
        let bridgeFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: bridgeDirectoryURL,
            includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for fileURL in bridgeFileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  var state = try? decoder.decode(GhosttyAgentBridgeState.self, from: data),
                  state.ghosttySurfaceID == surfaceID,
                  state.status == "done" else { continue }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            state.status = "idle"
            state.message = nil
            state.updatedAt = dateFormatter.string(from: Date())

            guard let updatedData = try? encoder.encode(state) else { continue }
            try? updatedData.write(to: fileURL, options: .atomic)
        }
    }
}
#endif
