import ActivityKit
import Foundation

struct SaywickActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
    }
    var startedAt: Date
    var engine: String
}
