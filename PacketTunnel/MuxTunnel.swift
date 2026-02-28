// MuxTunnel.swift – Multiplexed encrypted tunnel over a single TCP connection
// Mirrors Android MuxTunnel.kt

import Foundation
import CryptoKit

/// Multiplexed tunnel over a single encrypted TCP connection.
///
/// After the standard SimpleProtocol handshake, a mux-init frame `[0x00, 0x01, 0x00, 0x00]`
/// is sent to switch the server into mux mode.
///
/// All subsequent frames carry: `[cmd 1B] [streamID 4B BE] [payload...]`
///
/// Lifecycle: construct → connect() → openStream() / close()
final class MuxTunnel {

    // Mux protocol commands
    static let CMD_CONNECT: UInt8      = 0x01
    static let CMD_CONNECT_OK: UInt8   = 0x02
    static let CMD_CONNECT_FAIL: UInt8 = 0x03
    static let CMD_DATA: UInt8         = 0x04
    static let CMD_FIN: UInt8          = 0x05

    private let remoteHost: String
    private let remotePort: Int
    private let psk: Data

    private var fd: Int32 = -1

    // Encryption state
    private var sendKey: SymmetricKey!
    private var recvKey: SymmetricKey!
    private var noncePrefix = Data(count: 4)
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    // Thread safety
    private let writeLock = NSLock()

    // Stream management
    private var streams: [UInt32: MuxStream] = [:]
    private let streamsLock = NSLock()
    private var nextStreamId: UInt32 = 1
    private var closed = false
    private var readerThread: Thread?

    init(remoteHost: String, remotePort: Int, psk: Data) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.psk = psk
    }

    // MARK: - Public API

    /// Connect to the remote server, perform handshake, enter mux mode.
    func connect() throws {
        try openSocket()
        try performHandshake()
        // Send mux init frame: [0x00=mux] [version=1] [reserved 2B]
        try writeFrameInternal(Data([0x00, 0x01, 0x00, 0x00]))
        startReader()
    }

    /// Open a new multiplexed stream to a SOCKS5-style target address.
    func openStream(targetHost: String, targetPort: Int) throws -> MuxStream {
        guard !closed else { throw ProxyError.connectionClosed }

        let streamId = nextStreamId
        nextStreamId += 1

        let stream = MuxStream(id: streamId, tunnel: self)
        streamsLock.lock()
        streams[streamId] = stream
        streamsLock.unlock()

        let target = buildTargetAddress(host: targetHost, port: targetPort)
        sendMuxFrame(cmd: MuxTunnel.CMD_CONNECT, streamId: streamId, payload: target)

        try stream.waitForConnect()
        return stream
    }

    /// Send a mux frame. Thread-safe.
    func sendMuxFrame(cmd: UInt8, streamId: UInt32, payload: Data? = nil) {
        let payloadSize = payload?.count ?? 0
        var data = Data(capacity: 5 + payloadSize)
        data.append(cmd)
        var idBE = streamId.bigEndian
        data.append(Data(bytes: &idBE, count: 4))
        if let payload = payload {
            data.append(payload)
        }

        writeLock.lock()
        defer { writeLock.unlock() }
        try? writeFrameInternal(data)
    }

    var isClosed: Bool { closed }

    func close() {
        guard !closed else { return }
        closed = true

        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }

        readerThread?.cancel()
        readerThread = nil

        streamsLock.lock()
        let allStreams = Array(streams.values)
        streams.removeAll()
        streamsLock.unlock()

        for stream in allStreams {
            stream.onConnectionLost()
        }
    }

    func removeStream(_ streamId: UInt32) {
        streamsLock.lock()
        streams.removeValue(forKey: streamId)
        streamsLock.unlock()
    }

    /// Raw file descriptor, for protect() if needed.
    var fileDescriptor: Int32 { fd }

    // MARK: - Socket

    private func openSocket() throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(remoteHost, String(remotePort), &hints, &result)
        guard rc == 0, let addrInfo = result else {
            throw ProxyError.connectionFailed("getaddrinfo: \(rc)")
        }
        defer { freeaddrinfo(result) }

        var lastErr: Int32 = 0
        var ptr: UnsafeMutablePointer<addrinfo>? = addrInfo
        while let ai = ptr {
            let sock = Darwin.socket(ai.pointee.ai_family,
                                     ai.pointee.ai_socktype,
                                     ai.pointee.ai_protocol)
            if sock < 0 { ptr = ai.pointee.ai_next; continue }

            // Set TCP_NODELAY
            var yes: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

            if Darwin.connect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                fd = sock
                return
            }
            lastErr = errno
            Darwin.close(sock)
            ptr = ai.pointee.ai_next
        }

        throw ProxyError.connectionFailed("connect failed, errno=\(lastErr)")
    }

    // MARK: - Handshake

    private func performHandshake() throws {
        // 1. Generate 32-byte random nonce
        let nonce = randomBytes(32)
        noncePrefix = Data(nonce.prefix(4))

        // 2. Timestamp (8 bytes, big-endian)
        let timestamp = UInt64(Date().timeIntervalSince1970)
        var tsBE = timestamp.bigEndian
        let tsData = Data(bytes: &tsBE, count: 8)

        // 3. HMAC-SHA256(psk, nonce || timestamp)
        var hmacInput = Data()
        hmacInput.append(nonce)
        hmacInput.append(tsData)
        let hmac = Data(HMAC<SHA256>.authenticationCode(
            for: hmacInput,
            using: SymmetricKey(data: psk)
        ))

        // 4. Random padding (32-256 bytes to match server requirements)
        let padLen = Int.random(in: 32...256)
        var padLenBE = UInt16(padLen).bigEndian
        let padLenData = Data(bytes: &padLenBE, count: 2)
        let padding = randomBytes(padLen)

        // 5. Send: nonce(32) + timestamp(8) + hmac(32) + padLen(2) + padding
        var msg = Data(capacity: 74 + padLen)
        msg.append(nonce)
        msg.append(tsData)
        msg.append(hmac)
        msg.append(padLenData)
        msg.append(padding)
        try writeRaw(msg)

        // 6. Derive directional keys
        sendKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: nonce,
            info: Data("simple-c2s".utf8),
            outputByteCount: 32
        )
        recvKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: nonce,
            info: Data("simple-s2c".utf8),
            outputByteCount: 32
        )

        sendCounter = 0
        recvCounter = 0
    }

    // MARK: - Encrypted framing

    /// Write one encrypted frame. Caller must hold writeLock (or be in connect()).
    private func writeFrameInternal(_ data: Data) throws {
        // Encrypt 2-byte length
        let len = UInt16(data.count)
        var lenBE = len.bigEndian
        let lenData = Data(bytes: &lenBE, count: 2)

        let nonce1 = try makeNonce(sendCounter * 2)
        let sealed1 = try AES.GCM.seal(lenData, using: sendKey, nonce: nonce1)

        let nonce2 = try makeNonce(sendCounter * 2 + 1)
        let sealed2 = try AES.GCM.seal(data, using: sendKey, nonce: nonce2)

        sendCounter += 1

        var buf = Data(capacity: 18 + data.count + 16)
        buf.append(sealed1.ciphertext)
        buf.append(sealed1.tag)
        buf.append(sealed2.ciphertext)
        buf.append(sealed2.tag)
        try writeRaw(buf)
    }

    /// Read one decrypted frame. Only called from the reader thread.
    private func readFrameInternal() -> Data? {
        do {
            // Read encrypted length (2+16 = 18 bytes)
            let encLen = try readExact(18)
            let nonce1 = try makeNonce(recvCounter * 2)
            let box1 = try AES.GCM.SealedBox(
                nonce: nonce1,
                ciphertext: encLen.prefix(2),
                tag: encLen.suffix(16)
            )
            let lenData = try AES.GCM.open(box1, using: recvKey)

            let payloadLen = Int(lenData[lenData.startIndex]) << 8
                           | Int(lenData[lenData.startIndex + 1])
            if payloadLen == 0 { return nil }

            // Read encrypted payload
            let encPayload = try readExact(payloadLen + 16)
            let nonce2 = try makeNonce(recvCounter * 2 + 1)
            let box2 = try AES.GCM.SealedBox(
                nonce: nonce2,
                ciphertext: encPayload.prefix(payloadLen),
                tag: encPayload.suffix(16)
            )
            let payload = try AES.GCM.open(box2, using: recvKey)

            recvCounter += 1
            return payload
        } catch {
            return nil
        }
    }

    // MARK: - Background reader (demultiplexer)

    private func startReader() {
        let thread = Thread { [weak self] in
            self?.readerLoop()
        }
        thread.name = "mux-tunnel-reader"
        thread.qualityOfService = .userInitiated
        readerThread = thread
        thread.start()
    }

    private func readerLoop() {
        while !closed {
            guard let frame = readFrameInternal() else { break }
            if frame.count < 5 { continue }

            let cmd = frame[0]
            let streamId = UInt32(frame[1]) << 24
                         | UInt32(frame[2]) << 16
                         | UInt32(frame[3]) << 8
                         | UInt32(frame[4])
            let payload = frame.count > 5 ? Data(frame[5...]) : nil

            streamsLock.lock()
            let stream = streams[streamId]
            streamsLock.unlock()

            guard let stream = stream else { continue }

            switch cmd {
            case MuxTunnel.CMD_CONNECT_OK:
                stream.onConnectOk()
            case MuxTunnel.CMD_CONNECT_FAIL:
                let msg = payload.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown error"
                stream.onConnectFail(msg)
            case MuxTunnel.CMD_DATA:
                if let payload = payload {
                    stream.onData(payload)
                }
            case MuxTunnel.CMD_FIN:
                stream.onFin()
            default:
                break
            }
        }

        // Connection lost — notify all streams
        if !closed {
            close()
        }
    }

    // MARK: - Target address builder (SOCKS5-style)

    private func buildTargetAddress(host: String, port: Int) -> Data {
        var frame = Data()
        var addr4 = in_addr()
        var addr6 = in6_addr()

        if inet_pton(AF_INET, host, &addr4) == 1 {
            frame.append(0x01) // IPv4
            withUnsafeBytes(of: &addr4) { frame.append(contentsOf: $0) }
        } else if inet_pton(AF_INET6, host, &addr6) == 1 {
            frame.append(0x04) // IPv6
            withUnsafeBytes(of: &addr6) { frame.append(contentsOf: $0) }
        } else {
            // Domain name
            let domainBytes = Data(host.utf8)
            frame.append(0x03)
            frame.append(UInt8(domainBytes.count))
            frame.append(domainBytes)
        }

        var portBE = UInt16(port).bigEndian
        frame.append(Data(bytes: &portBE, count: 2))
        return frame
    }

    // MARK: - AES-GCM nonce

    private func makeNonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        var nonceData = Data(noncePrefix.prefix(4))
        var counterBE = counter.bigEndian
        nonceData.append(Data(bytes: &counterBE, count: 8))
        return try AES.GCM.Nonce(data: nonceData)
    }

    // MARK: - Raw I/O

    private func writeRaw(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written <= 0 { throw ProxyError.connectionClosed }
            offset += written
        }
    }

    private func readExact(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            if n <= 0 { throw ProxyError.connectionClosed }
            offset += n
        }
        return buffer
    }

    private func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
