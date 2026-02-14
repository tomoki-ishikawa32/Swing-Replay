import Foundation
import MultipeerConnectivity
import OSLog

public final class PhoneSenderSession: NSObject, @unchecked Sendable {
    public private(set) var state: ConnectionState = .searching {
        didSet { stateDidChange?(state) }
    }

    public var stateDidChange: ((ConnectionState) -> Void)?

    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let logger = Logger(subsystem: "SwingReplay", category: "PhoneSender")

    public init(peerID: MCPeerID = PeerIdentity.makePeerID(prefix: "phone")) {
        self.peerID = peerID
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        self.advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: MultipeerConfig.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
    }

    public func start() {
        advertiser.startAdvertisingPeer()
        state = .searching
        logger.info("Advertising started")
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        state = .searching
        logger.info("Sender stopped")
    }

    public func send(_ data: Data, reliably: Bool) throws {
        guard !session.connectedPeers.isEmpty else {
            throw SenderError.noConnectedPeer
        }

        let mode: MCSessionSendDataMode = reliably ? .reliable : .unreliable
        try session.send(data, toPeers: session.connectedPeers, with: mode)
    }

    private func recoverAdvertising() {
        advertiser.stopAdvertisingPeer()
        advertiser.startAdvertisingPeer()
        state = .reconnecting
        logger.notice("Re-advertising after disconnect")
    }
}

public enum SenderError: Error {
    case noConnectedPeer
}

extension PhoneSenderSession: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        state = .connecting
        invitationHandler(true, session)
        logger.info("Invitation accepted from \(peerID.displayName, privacy: .public)")
    }

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        state = .error(message: error.localizedDescription)
        logger.error("Advertiser start failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension PhoneSenderSession: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .notConnected:
            recoverAdvertising()
        case .connecting:
            self.state = .connecting
        case .connected:
            self.state = .connected(peerName: peerID.displayName)
        @unknown default:
            self.state = .error(message: "Unknown session state")
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        logger.debug("Unexpected data received on sender side size=\(data.count)")
    }

    public func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        logger.debug("Stream ignored: \(streamName, privacy: .public)")
    }

    public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        logger.debug("Resource receiving started: \(resourceName, privacy: .public)")
    }

    public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: (any Error)?
    ) {
        logger.debug("Resource receiving finished: \(resourceName, privacy: .public)")
    }
}
