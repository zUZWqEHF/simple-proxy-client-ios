// PacketTunnelProvider.swift – Network Extension entry point
// Bridges sing-box (Libbox) + SimpleProtocol for VPN tunnelling.

import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var boxService: LibboxBoxService?
    private var platformInterface: SingBoxPlatformInterface?
    private var bridge: SimpleProtocolBridge?

    // MARK: - Tunnel lifecycle

    override func startTunnel(options: [String: NSObject]?) async throws {
        NSLog("[PacketTunnel] startTunnel")

        // ── 1. Read node configuration from provider ──
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration else {
            throw tunnelError("Missing provider configuration")
        }

        guard let host = config["host"] as? String,
              let port = config["port"] as? Int,
              let keyHex = config["key"] as? String,
              let pskData = hexToData(keyHex),
              pskData.count == 32 else {
            throw tunnelError("Invalid SimpleProtocol node configuration")
        }

        let routingMode = (config["routingMode"] as? String) ?? "global"
        NSLog("[PacketTunnel] node: %@:%d  routingMode: %@", host, port, routingMode)

        // ── 2. Setup Libbox paths ──
        LibboxClearServiceError()

        let setupOpts = LibboxSetupOptions()
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.app.rork.simple-proxy-client"
        )!

        // basePath is where Libbox creates command.sock (Unix domain socket).
        // Unix sockets have a path limit (~104 chars), so we use the shorter
        // NSTemporaryDirectory instead of the app group container.
        let basePath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sb")
        let workPath = container.appendingPathComponent("singbox")
            .appendingPathComponent("work")
        let tmpPath  = container.appendingPathComponent("singbox")
            .appendingPathComponent("tmp")

        for dir in [basePath, workPath, tmpPath] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        setupOpts.basePath    = basePath.path
        setupOpts.workingPath = workPath.path
        setupOpts.tempPath    = tmpPath.path

        var setupErr: NSError?
        LibboxSetup(setupOpts, &setupErr)
        if let err = setupErr {
            throw tunnelError("Libbox setup: \(err.localizedDescription)")
        }

        // ── 3. Start SimpleProtocol SOCKS5 bridge ──
        bridge = SimpleProtocolBridge(remoteHost: host, remotePort: port, psk: pskData)
        try bridge?.start(port: 16080)

        // ── 4. Create platform interface & command server ──
        platformInterface = SingBoxPlatformInterface(tunnel: self, serverAddress: host)
        commandServer = LibboxNewCommandServer(platformInterface, 300)
        do {
            try commandServer?.start()
        } catch {
            // Command server uses Unix domain socket which exceeds iOS path limit.
            // Non-essential for VPN — log and continue.
            NSLog("[PacketTunnel] command server skipped: %@", error.localizedDescription)
            commandServer = nil
        }

        // ── 5. Generate sing-box config and start service ──
        let configJSON = SingBoxConfigBuilder.build(
            routingMode: routingMode,
            bridgePort: 16080,
            workDir: workPath
        )

        var serviceErr: NSError?
        let service = LibboxNewService(configJSON, platformInterface, &serviceErr)
        if let err = serviceErr {
            throw tunnelError("Libbox service create: \(err.localizedDescription)")
        }
        guard let service else {
            throw tunnelError("Libbox service is nil")
        }

        try service.start()
        commandServer?.setService(service)
        boxService = service

        NSLog("[PacketTunnel] started successfully")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        NSLog("[PacketTunnel] stopTunnel reason=%ld", reason.rawValue)

        bridge?.stop()
        bridge = nil

        if let service = boxService {
            try? service.close()
            boxService = nil
        }
        commandServer?.setService(nil)
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms drain
            try? server.close()
            commandServer = nil
        }

        platformInterface?.reset()
        platformInterface = nil
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        messageData
    }

    override func sleep() async {
        boxService?.pause()
    }

    override func wake() {
        boxService?.wake()
    }

    // MARK: - Helpers

    func writeMessage(_ msg: String) {
        commandServer?.writeMessage(msg)
    }

    private func tunnelError(_ msg: String) -> NSError {
        NSLog("[PacketTunnel] ERROR: %@", msg)
        return NSError(domain: "SimpleProxy.PacketTunnel", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var chars = Array(hex)
        while chars.count >= 2 {
            guard let byte = UInt8(String(chars.prefix(2)), radix: 16) else { return nil }
            data.append(byte)
            chars.removeFirst(2)
        }
        return data
    }

}
