import ActivityKit
import Foundation

struct ListeningAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isListening: Bool
        var modeLabel: String
        var statusLine: String
        var listeningLabel: String
    }

    var appName: String
}
