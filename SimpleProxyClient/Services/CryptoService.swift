import Foundation
import CryptoKit

nonisolated enum CryptoService: Sendable {

    static func evpBytesToKey(password: String, keyLen: Int) -> Data {
        var key = Data()
        var lastHash = Data()
        let passData = Data(password.utf8)
        while key.count < keyLen {
            var input = lastHash
            input.append(passData)
            lastHash = Data(Insecure.MD5.hash(data: input))
            key.append(lastHash)
        }
        return Data(key.prefix(keyLen))
    }

    static func ssSubkey(masterKey: Data, salt: Data) -> SymmetricKey {
        HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: salt,
            info: Data("ss-subkey".utf8),
            outputByteCount: masterKey.count
        )
    }

    static func deriveSimpleSessionKey(psk: Data, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: nonce,
            info: Data("simple-data".utf8),
            outputByteCount: 32
        )
    }

    static func encryptAESGCM(plaintext: Data, key: SymmetricKey, nonce: AES.GCM.Nonce) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        return sealed.ciphertext + sealed.tag
    }

    static func decryptAESGCM(ciphertext: Data, key: SymmetricKey, nonce: AES.GCM.Nonce) throws -> Data {
        let tagSize = 16
        guard ciphertext.count >= tagSize else { throw CryptoError.invalidData }
        let ct = ciphertext.prefix(ciphertext.count - tagSize)
        let tag = ciphertext.suffix(tagSize)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    static func encryptChaChaPoly(plaintext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce) throws -> Data {
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        return sealed.ciphertext + sealed.tag
    }

    static func decryptChaChaPoly(ciphertext: Data, key: SymmetricKey, nonce: ChaChaPoly.Nonce) throws -> Data {
        let tagSize = 16
        guard ciphertext.count >= tagSize else { throw CryptoError.invalidData }
        let ct = ciphertext.prefix(ciphertext.count - tagSize)
        let tag = ciphertext.suffix(tagSize)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: key)
    }

    static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func makeAESGCMNonce(counter: UInt64, prefix: Data) throws -> AES.GCM.Nonce {
        var nonceData = Data(prefix.prefix(4))
        var be = counter.bigEndian
        nonceData.append(Data(bytes: &be, count: 8))
        return try AES.GCM.Nonce(data: nonceData)
    }

    static func makeChaChaNonce(counter: UInt64, prefix: Data) throws -> ChaChaPoly.Nonce {
        var nonceData = Data(prefix.prefix(4))
        var be = counter.bigEndian
        nonceData.append(Data(bytes: &be, count: 8))
        return try ChaChaPoly.Nonce(data: nonceData)
    }

    static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var chars = Array(hex)
        while chars.count >= 2 {
            guard let byte = UInt8(String(chars.prefix(2)), radix: 16) else { return nil }
            data.append(byte)
            chars.removeFirst(2)
        }
        return data
    }

    static func dataToHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CryptoError: Error, Sendable {
    case invalidData
    case authenticationFailed
    case invalidNonce
}
