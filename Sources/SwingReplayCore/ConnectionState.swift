public enum ConnectionState: Equatable, Sendable {
    case searching
    case connecting
    case connected(peerName: String)
    case reconnecting
    case error(message: String)
}
