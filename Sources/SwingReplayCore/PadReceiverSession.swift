import Foundation
import MultipeerConnectivity
import OSLog

public final class PadReceiverSession: NSObject, @unchecked Sendable {
    public private(set) var state: ConnectionState = .searching {
        didSet { stateDidChange?(state) }
    }

    public var stateDidChange: ((ConnectionState) -> Void)?
    public var didReceiveData: ((Data, MCPeerID) -> Void)?

    private let peerID: MCPeerID
    private let session: MCSession
    private let browser: MCNearbyServiceBrowser
    private let logger = Logger(subsystem: "SwingReplay", category: "PadReceiver")
    private var lastInviteAtByPeer: [String: Date] = [:]
    private let inviteCooldown: TimeInterval = 3

    public init(peerID: MCPeerID = PeerIdentity.makePeerID(prefix: "pad")) {
        self.peerID = peerID
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        self.browser = MCNearbyServiceBrowser(peer: peerID, serviceType: MultipeerConfig.serviceType)
        super.init()
        session.delegate = self
        browser.delegate = self
    }

    public func start() {
        browser.startBrowsingForPeers()
        state = .searching
        logger.info("Browsing started")
    }

    public func stop() {
        browser.stopBrowsingForPeers()
        session.disconnect()
        state = .searching
        logger.info("Receiver stopped")
    }

    private func reBrowse() {
        browser.stopBrowsingForPeers()
        browser.startBrowsingForPeers()
        state = .reconnecting
        logger.notice("Re-browsing after disconnect")
    }
}

extension PadReceiverSession: MCNearbyServiceBrowserDelegate {
    public func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        if !session.connectedPeers.isEmpty {
            return
        }
        let now = Date()
        if let lastInviteAt = lastInviteAtByPeer[peerID.displayName],
           now.timeIntervalSince(lastInviteAt) < inviteCooldown {
            return
        }
        lastInviteAtByPeer[peerID.displayName] = now
        state = .connecting
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
        logger.info("Inviting peer \(peerID.displayName, privacy: .public)")
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        lastInviteAtByPeer.removeValue(forKey: peerID.displayName)
        if session.connectedPeers.isEmpty {
            reBrowse()
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        state = .error(message: error.localizedDescription)
        logger.error("Browsing failed: \(error.localizedDescription, privacy: .public)")
    }
}

extension PadReceiverSession: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .notConnected:
            lastInviteAtByPeer.removeValue(forKey: peerID.displayName)
            reBrowse()
        case .connecting:
            self.state = .connecting
        case .connected:
            self.state = .connected(peerName: peerID.displayName)
        @unknown default:
            self.state = .error(message: "Unknown session state")
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        didReceiveData?(data, peerID)
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
