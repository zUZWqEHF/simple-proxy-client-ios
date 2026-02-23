import Foundation

nonisolated enum ProxyProtocolType: String, Codable, Sendable, CaseIterable, Identifiable {
    case shadowsocks = "Shadowsocks"
    case simpleProtocol = "SimpleProtocol"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var shortName: String {
        switch self {
        case .shadowsocks: "SS"
        case .simpleProtocol: "SP"
        }
    }
}

nonisolated enum ShadowsocksCipher: String, Codable, Sendable, CaseIterable, Identifiable {
    case aes128Gcm = "aes-128-gcm"
    case aes256Gcm = "aes-256-gcm"
    case chacha20Poly1305 = "chacha20-ietf-poly1305"

    var id: String { rawValue }

    var keySize: Int {
        switch self {
        case .aes128Gcm: 16
        case .aes256Gcm, .chacha20Poly1305: 32
        }
    }
}

nonisolated enum RoutingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case global = "Global"
    case bypassChina = "Bypass CN"

    var id: String { rawValue }
}

nonisolated enum ConnectionStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting

    var displayText: String {
        switch self {
        case .disconnected: "Not Connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        }
    }

    var isActive: Bool {
        self == .connected || self == .connecting
    }
}

nonisolated struct ProxyNode: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var protocolType: ProxyProtocolType
    var ssCipher: ShadowsocksCipher?
    var ssPassword: String?
    var spKey: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        protocolType: ProxyProtocolType,
        ssCipher: ShadowsocksCipher? = nil,
        ssPassword: String? = nil,
        spKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.protocolType = protocolType
        self.ssCipher = ssCipher
        self.ssPassword = ssPassword
        self.spKey = spKey
    }

    var subtitle: String {
        "\(protocolType.shortName) · \(host):\(port)"
    }
}
