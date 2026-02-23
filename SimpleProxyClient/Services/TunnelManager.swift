import Foundation
import NetworkExtension

@Observable
final class TunnelManager {
    private(set) var status: ConnectionStatus = .disconnected
    private var manager: NETunnelProviderManager?

    init() {
        loadManager()
        observeStatus()
    }

    private func loadManager() {
        Task {
            let managers = try? await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers?.first ?? NETunnelProviderManager()
        }
    }

    private func observeStatus() {
        Task {
            for await notification in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange) {
                guard let connection = notification.object as? NEVPNConnection else { continue }
                updateStatus(connection.status)
            }
        }
    }

    private func updateStatus(_ vpnStatus: NEVPNStatus) {
        status = switch vpnStatus {
        case .connected: .connected
        case .connecting, .reasserting: .connecting
        case .disconnecting: .disconnecting
        default: .disconnected
        }
    }

    func startTunnel(node: ProxyNode, routingMode: RoutingMode) async throws {
        let mgr = manager ?? NETunnelProviderManager()
        self.manager = mgr

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "app.rork.simple-proxy-client.PacketTunnel"
        proto.serverAddress = "\(node.host):\(node.port)"

        // Only SimpleProtocol is supported (matching Android)
        let config: [String: Any] = [
            "host": node.host,
            "port": node.port,
            "key": node.spKey ?? "",
            "routingMode": routingMode.rawValue == "Bypass CN" ? "bypassChina" : "global",
        ]

        proto.providerConfiguration = config
        proto.disconnectOnSleep = false
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "simple proxy"
        mgr.isEnabled = true

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()
        try mgr.connection.startVPNTunnel()
    }

    func stopTunnel() {
        manager?.connection.stopVPNTunnel()
    }
}
