// ProxyTunnel.swift – SimpleProtocol encrypted tunnel (mirrors Android ProxyTunnel.kt)

import Foundation
import CryptoKit

enum ProxyError: Error, LocalizedError {
    case connectionFailed(String)
    case connectionClosed
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .connectionClosed: return "Connection closed"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        }
    }
}

/// SimpleProtocol encrypted tunnel over a raw TCP socket.
/// Matches the Android `ProxyTunnel` framing exactly.
final class ProxyTunnel {

    private let psk: Data
    private var fd: Int32 = -1

    private var sendKey: SymmetricKey!
    private var recvKey: SymmetricKey!
    private var noncePrefix = Data(count: 4)
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    // MARK: - Init

    init(psk: Data) {
        self.psk = psk
    }

    // MARK: - Public API

    /// Connect to the remote proxy server and perform the SimpleProtocol handshake.
    /// `targetHost`/`targetPort` is the final destination that the proxy should relay to.
    func connect(serverHost: String, serverPort: Int,
                 targetHost: String, targetPort: Int) throws {
        try openSocket(host: serverHost, port: serverPort)
        try handshake()
        try sendTargetAddress(host: targetHost, port: targetPort)
    }

    /// Attach to an already-connected file descriptor (for reuse).
    func attach(fd: Int32) {
        self.fd = fd
    }

    func writeFrame(_ data: Data) throws {
        // Encrypt 2-byte length
        let len = UInt16(data.count)
        var lenBE = len.bigEndian
        let lenData = Data(bytes: &lenBE, count: 2)

        let nonce1 = try makeNonce(sendCounter)
        let sealed1 = try AES.GCM.seal(lenData, using: sendKey, nonce: nonce1)
        sendCounter += 1

        // Encrypt payload
        let nonce2 = try makeNonce(sendCounter)
        let sealed2 = try AES.GCM.seal(data, using: sendKey, nonce: nonce2)
        sendCounter += 1

        // Write: encLen(2+16) + encPayload(len+16)
        var buf = Data(capacity: 18 + data.count + 16)
        buf.append(sealed1.ciphertext)
        buf.append(sealed1.tag)
        buf.append(sealed2.ciphertext)
        buf.append(sealed2.tag)
        try writeRaw(buf)
    }

    func readFrame() throws -> Data {
        // Read encrypted length (18 bytes)
        let encLen = try readExact(18)
        let nonce1 = try makeNonce(recvCounter)
        let box1 = try AES.GCM.SealedBox(
            nonce: nonce1,
            ciphertext: encLen.prefix(2),
            tag: encLen.suffix(16)
        )
        let lenData = try AES.GCM.open(box1, using: recvKey)
        recvCounter += 1

        let payloadLen = Int(lenData[lenData.startIndex]) << 8
                       | Int(lenData[lenData.startIndex + 1])

        // Read encrypted payload
        let encPayload = try readExact(payloadLen + 16)
        let nonce2 = try makeNonce(recvCounter)
        let box2 = try AES.GCM.SealedBox(
            nonce: nonce2,
            ciphertext: encPayload.prefix(payloadLen),
            tag: encPayload.suffix(16)
        )
        let payload = try AES.GCM.open(box2, using: recvKey)
        recvCounter += 1
        return payload
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    var fileDescriptor: Int32 { fd }

    // MARK: - Socket helpers

    private func openSocket(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
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

    private func handshake() throws {
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

        // 4. Random padding (32-256 bytes to match server requirement)
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
    }

    // MARK: - Target address (first encrypted frame)

    private func sendTargetAddress(host: String, port: Int) throws {
        var frame = Data()
        var addr4 = in_addr()
        var addr6 = in6_addr()

        if inet_pton(AF_INET, host, &addr4) == 1 {
            // IPv4
            frame.append(0x01)
            withUnsafeBytes(of: &addr4) { frame.append(contentsOf: $0) }
        } else if inet_pton(AF_INET6, host, &addr6) == 1 {
            // IPv6
            frame.append(0x04)
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
        try writeFrame(frame)
    }

    // MARK: - AES-GCM nonce

    private func makeNonce(_ counter: UInt64) throws -> AES.GCM.Nonce {
        var nonceData = Data(noncePrefix.prefix(4))
        var counterBE = counter.bigEndian
        nonceData.append(Data(bytes: &counterBE, count: 8))
        return try AES.GCM.Nonce(data: nonceData)
    }

    // MARK: - Raw I/O

    func writeRaw(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written <= 0 { throw ProxyError.connectionClosed }
            offset += written
        }
    }

    func readExact(_ count: Int) throws -> Data {
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

    // MARK: - Helpers

    private func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
