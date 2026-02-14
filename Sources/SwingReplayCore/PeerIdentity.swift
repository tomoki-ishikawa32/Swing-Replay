import Foundation
import MultipeerConnectivity

public enum PeerIdentity {
    public static func makePeerID(prefix: String) -> MCPeerID {
        let baseName = ProcessInfo.processInfo.processName
        let suffix = ProcessInfo.processInfo.globallyUniqueString.prefix(8)
        let rawName = "\(baseName)-\(suffix)"

        let sanitized = rawName
            .replacingOccurrences(of: " ", with: "-")
            .prefix(30)

        return MCPeerID(displayName: "\(prefix)-\(sanitized)")
    }
}

public enum MultipeerConfig {
    public static let serviceType = "swing-replay"
}
