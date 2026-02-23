// SimpleProtocolBridge.swift – SOCKS5 server bridging to SimpleProtocol via MuxTunnel
// Mirrors Android's SimpleProtocolSocksBridge.kt (mux-based)

import Foundation

/// Listens on a local SOCKS5 port and translates each connection into
/// a multiplexed stream through a shared MuxTunnel.
final class SimpleProtocolBridge {

    private let remoteHost: String
    private let remotePort: Int
    private let psk: Data

    private var listenFd: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "sp-bridge", attributes: .concurrent)

    // Shared mux tunnel (lazy, reconnects on failure)
    private var muxTunnel: MuxTunnel?
    private let muxLock = NSLock()

    init(remoteHost: String, remotePort: Int, psk: Data) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.psk = psk
    }

    // MARK: - Start / Stop

    func start(port: UInt16 = 16080) throws {
        listenFd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenFd >= 0 else {
            throw ProxyError.connectionFailed("socket(): \(errno)")
        }

        var yes: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(listenFd); listenFd = -1
            throw ProxyError.connectionFailed("bind(): \(errno)")
        }

        guard Darwin.listen(listenFd, 128) == 0 else {
            Darwin.close(listenFd); listenFd = -1
            throw ProxyError.connectionFailed("listen(): \(errno)")
        }

        running = true
        queue.async { [weak self] in self?.acceptLoop() }
        NSLog("[Bridge] listening on 127.0.0.1:\(port)")
    }

    func stop() {
        running = false
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
        muxLock.lock()
        muxTunnel?.close()
        muxTunnel = nil
        muxLock.unlock()
    }

    // MARK: - Shared MuxTunnel

    /// Get or create a shared MuxTunnel. Reconnects if the existing tunnel is dead.
    private func getOrCreateMuxTunnel() throws -> MuxTunnel {
        muxLock.lock()
        defer { muxLock.unlock() }

        if let tunnel = muxTunnel, !tunnel.isClosed {
            return tunnel
        }

        NSLog("[Bridge] creating new MuxTunnel to %@:%d", remoteHost, remotePort)
        let tunnel = MuxTunnel(remoteHost: remoteHost, remotePort: remotePort, psk: psk)
        try tunnel.connect()
        muxTunnel = tunnel
        return tunnel
    }

    /// Invalidate the current tunnel (called when a stream detects a broken tunnel).
    private func invalidateMuxTunnel(_ tunnel: MuxTunnel) {
        muxLock.lock()
        defer { muxLock.unlock() }
        if muxTunnel === tunnel {
            tunnel.close()
            muxTunnel = nil
        }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while running {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenFd, sa, &len)
                }
            }
            guard clientFd >= 0 else {
                if !running { break }
                continue
            }
            queue.async { [weak self] in
                self?.handleClient(clientFd)
            }
        }
    }

    // MARK: - Per-connection handler (mux-based)

    private func handleClient(_ clientFd: Int32) {
        defer { Darwin.close(clientFd) }

        do {
            // ── SOCKS5 auth negotiation ──
            let authReq = try readBytes(clientFd, count: 2)
            guard authReq[0] == 0x05 else { return }
            let nmethods = Int(authReq[1])
            _ = try readBytes(clientFd, count: nmethods)
            try writeBytes(clientFd, data: Data([0x05, 0x00]))

            // ── SOCKS5 connect request ──
            let hdr = try readBytes(clientFd, count: 4)
            guard hdr[0] == 0x05, hdr[1] == 0x01 else { return }

            let (targetHost, targetPort) = try parseSocks5Address(clientFd, addrType: hdr[3])

            // ── Open mux stream through shared tunnel ──
            var tunnel: MuxTunnel
            var stream: MuxStream
            do {
                tunnel = try getOrCreateMuxTunnel()
                stream = try tunnel.openStream(targetHost: targetHost, targetPort: targetPort)
            } catch {
                // On MuxTunnel failure, invalidate and retry once
                NSLog("[Bridge] mux tunnel error, retrying: \(error)")
                if let t = muxTunnel { invalidateMuxTunnel(t) }
                tunnel = try getOrCreateMuxTunnel()
                stream = try tunnel.openStream(targetHost: targetHost, targetPort: targetPort)
            }
            defer { stream.close() }

            // ── SOCKS5 success reply ──
            try writeBytes(clientFd, data: Data([
                0x05, 0x00, 0x00, 0x01,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00
            ]))

            // ── Bidirectional relay via mux stream ──
            relayMux(clientFd: clientFd, stream: stream, tunnel: tunnel)

        } catch {
            NSLog("[Bridge] client error: \(error)")
        }
    }

    // MARK: - SOCKS5 address parsing

    private func parseSocks5Address(_ fd: Int32, addrType: UInt8) throws -> (String, Int) {
        let host: String
        switch addrType {
        case 0x01: // IPv4
            let ipBytes = try readBytes(fd, count: 4)
            host = ipBytes.map { String($0) }.joined(separator: ".")
        case 0x03: // Domain
            let lenByte = try readBytes(fd, count: 1)
            let domainBytes = try readBytes(fd, count: Int(lenByte[0]))
            host = String(data: domainBytes, encoding: .utf8) ?? ""
        case 0x04: // IPv6
            let ipBytes = try readBytes(fd, count: 16)
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                parts.append(String(format: "%02x%02x", ipBytes[i], ipBytes[i+1]))
            }
            host = parts.joined(separator: ":")
        default:
            throw ProxyError.protocolError("unsupported SOCKS5 addr type: \(addrType)")
        }

        let portBytes = try readBytes(fd, count: 2)
        let port = Int(portBytes[0]) << 8 | Int(portBytes[1])
        return (host, port)
    }

    // MARK: - Bidirectional relay (mux-based)

    private func relayMux(clientFd: Int32, stream: MuxStream, tunnel: MuxTunnel) {
        let done = DispatchGroup()

        // client → mux stream
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            let bufSize = 16384
            var buf = [UInt8](repeating: 0, count: bufSize)
            while true {
                let n = Darwin.read(clientFd, &buf, bufSize)
                if n <= 0 { break }
                stream.write(Data(buf[0..<n]))
            }
            stream.close()
        }

        // mux stream → client
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            while let data = stream.read() {
                var offset = 0
                while offset < data.count {
                    let written = data.withUnsafeBytes { ptr in
                        Darwin.write(clientFd, ptr.baseAddress!.advanced(by: offset),
                                     data.count - offset)
                    }
                    if written <= 0 { return }
                    offset += written
                }
            }
            Darwin.shutdown(clientFd, SHUT_WR)
        }

        done.wait()
    }

    // MARK: - Low-level I/O helpers

    private func readBytes(_ fd: Int32, count: Int) throws -> Data {
        var buf = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            if n <= 0 { throw ProxyError.connectionClosed }
            offset += n
        }
        return buf
    }

    private func writeBytes(_ fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n <= 0 { throw ProxyError.connectionClosed }
            offset += n
        }
    }
}
